// RV32I directed-test harness: multi-cycle core with APB3 master memory port.
// Integrates alu / regfile / control for end-to-end I-type execution flows.
// Cocotb preloads a pseudo-memory (APB slave) and observes fetched_data / PC.
module instruction_isa_core (
    input  logic        clk,
    input  logic        rst_n,

    // Run control
    input  logic        start,
    input  logic [31:0] entry_pc,
    input  logic [31:0] step_limit,
    output logic        busy,
    output logic        done,
    output logic        trap_illegal,

    // Observation ports for directed tests
    output logic [31:0] pc,
    output logic [31:0] fetched_data,
    output logic [31:0] instr_count,
    input  logic [4:0]  peek_raddr,
    output logic [31:0] peek_rdata,

    // APB3 master (instruction + data memory)
    output logic        PSEL,
    output logic        PENABLE,
    output logic        PWRITE,
    output logic [31:0] PADDR,
    output logic [31:0] PWDATA,
    input  logic [31:0] PRDATA,
    input  logic        PREADY
);

  // ---------------------------------------------------------------------------
  // Phases / FSM
  // ---------------------------------------------------------------------------
  localparam logic [1:0] PHASE_DEC = 2'd0;
  localparam logic [1:0] PHASE_EX  = 2'd1;
  localparam logic [1:0] PHASE_MEM = 2'd2;
  localparam logic [1:0] PHASE_WB  = 2'd3;

  localparam logic [3:0] ST_IDLE        = 4'd0;
  localparam logic [3:0] ST_FETCH_SETUP = 4'd1;
  localparam logic [3:0] ST_FETCH_ACC   = 4'd2;
  localparam logic [3:0] ST_DEC         = 4'd3;
  localparam logic [3:0] ST_EX          = 4'd4;
  localparam logic [3:0] ST_MEM_SETUP   = 4'd5;
  localparam logic [3:0] ST_MEM_ACC     = 4'd6;
  localparam logic [3:0] ST_WB          = 4'd7;
  localparam logic [3:0] ST_NEXT        = 4'd8;
  localparam logic [3:0] ST_DONE        = 4'd9;

  localparam logic [6:0] OPC_LOAD   = 7'b0000011;
  localparam logic [6:0] OPC_AUIPC  = 7'b0010111;
  localparam logic [6:0] OPC_STORE  = 7'b0100011;
  localparam logic [6:0] OPC_LUI    = 7'b0110111;
  localparam logic [6:0] OPC_BRANCH = 7'b1100011;
  localparam logic [6:0] OPC_JALR   = 7'b1100111;
  localparam logic [6:0] OPC_JAL    = 7'b1101111;
  localparam logic [6:0] OPC_SYSTEM = 7'b1110011;

  logic [3:0]  state, state_n;
  logic [31:0] pc_r, pc_n;
  logic [31:0] instr_r;
  logic [31:0] fetched_r, fetched_n;
  logic [31:0] alu_a, alu_b, alu_y;
  logic [31:0] rs1_v, rs2_v;
  logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;
  logic [31:0] wb_data;
  logic [31:0] next_pc;
  logic [31:0] next_pc_r;
  logic [31:0] step_r, step_n;
  logic [31:0] icount_r, icount_n;
  logic        busy_r, done_r, trap_r;
  logic        branch_taken;
  logic        do_mem;
  logic        is_load;
  logic        is_store;
  logic        is_jal;
  logic        is_jalr;
  logic        is_branch;
  logic        is_lui;
  logic        is_auipc;
  logic        is_ebreak;
  logic        rf_we;
  logic [4:0]  rf_waddr;
  logic [31:0] rf_wdata;
  logic [1:0]  phase;
  logic [11:0] ctrl;
  logic [3:0]  alu_op;
  logic        ctrl_illegal;
  logic        ctrl_reg_write;
  logic        ctrl_mem_read;
  logic        ctrl_mem_write;
  logic        ctrl_branch;
  logic        ctrl_jump;
  logic        ctrl_alu_src_imm;
  logic [6:0]  opcode;
  logic [2:0]  funct3;
  logic [4:0]  rd, rs1, rs2;

  // ---------------------------------------------------------------------------
  // Datapath units
  // ---------------------------------------------------------------------------
  control u_control (
      .inst     (instr_r),
      .phase    (phase),
      .ctrl_out (ctrl)
  );

  alu u_alu (
      .in1     (alu_a),
      .in2     (alu_b),
      .control (alu_op),
      .alu_out (alu_y)
  );

  regfile u_regfile (
      .clk    (clk),
      .rst_n  (rst_n),
      .we     (rf_we),
      .waddr  (rf_waddr),
      .wdata  (rf_wdata),
      .raddr1 (rs1),
      .raddr2 ((state == ST_DONE) ? peek_raddr : rs2),
      .rdata1 (rs1_v),
      .rdata2 (rs2_v)
  );

  assign ctrl_reg_write   = ctrl[0];
  assign ctrl_mem_write   = ctrl[1];
  assign ctrl_mem_read    = ctrl[2];
  assign alu_op           = ctrl[6:3];
  assign ctrl_alu_src_imm = ctrl[7];
  assign ctrl_branch      = ctrl[8];
  assign ctrl_jump        = ctrl[9];
  assign ctrl_illegal     = ctrl[11];

  assign opcode = instr_r[6:0];
  assign rd     = instr_r[11:7];
  assign funct3 = instr_r[14:12];
  assign rs1    = instr_r[19:15];
  assign rs2    = instr_r[24:20];

  assign imm_i = {{20{instr_r[31]}}, instr_r[31:20]};
  assign imm_s = {{20{instr_r[31]}}, instr_r[31:25], instr_r[11:7]};
  assign imm_b = {{19{instr_r[31]}}, instr_r[31], instr_r[7],
                  instr_r[30:25], instr_r[11:8], 1'b0};
  assign imm_u = {instr_r[31:12], 12'b0};
  assign imm_j = {{11{instr_r[31]}}, instr_r[31], instr_r[19:12],
                  instr_r[20], instr_r[30:21], 1'b0};

  assign is_load   = (opcode == OPC_LOAD);
  assign is_store  = (opcode == OPC_STORE);
  assign is_jal    = (opcode == OPC_JAL);
  assign is_jalr   = (opcode == OPC_JALR);
  assign is_branch = (opcode == OPC_BRANCH);
  assign is_lui    = (opcode == OPC_LUI);
  assign is_auipc  = (opcode == OPC_AUIPC);
  assign is_ebreak = (opcode == OPC_SYSTEM) && (instr_r[31:7] == 25'h0002000);
  assign do_mem    = is_load || is_store;

  // Peek reuses regfile port 2 while halted; during execute rs2 drives it.
  assign peek_rdata = rs2_v;

  // ALU operand steering for I-type execution paths.
  always_comb begin
    alu_a = rs1_v;
    alu_b = ctrl_alu_src_imm ? imm_i : rs2_v;
    if (is_lui) begin
      alu_a = 32'h0;
      alu_b = imm_u;
    end else if (is_auipc) begin
      alu_a = pc_r;
      alu_b = imm_u;
    end else if (is_store) begin
      alu_a = rs1_v;
      alu_b = imm_s;
    end else if (is_jal || is_jalr) begin
      // Link value computed as PC+4 in WB; ALU used for JALR target.
      alu_a = rs1_v;
      alu_b = imm_i;
    end else if (is_branch && (funct3 == 3'b000 || funct3 == 3'b001)) begin
      alu_a = rs1_v;
      alu_b = rs2_v;
    end
  end

  // Branch decision (BNE + BLE-family via BGE/BLT encodings).
  always_comb begin
    branch_taken = 1'b0;
    unique case (funct3)
      3'b000: branch_taken = (rs1_v == rs2_v);                         // BEQ
      3'b001: branch_taken = (rs1_v != rs2_v);                         // BNE
      3'b100: branch_taken = ($signed(rs1_v) <  $signed(rs2_v));       // BLT
      3'b101: branch_taken = ($signed(rs1_v) >= $signed(rs2_v));       // BGE
      3'b110: branch_taken = (rs1_v <  rs2_v);                         // BLTU
      3'b111: branch_taken = (rs1_v >= rs2_v);                         // BGEU
      default: branch_taken = 1'b0;
    endcase
  end

  always_comb begin
    next_pc = pc_r + 32'd4;
    if (is_branch && branch_taken)
      next_pc = pc_r + imm_b;
    else if (is_jal)
      next_pc = pc_r + imm_j;
    else if (is_jalr)
      next_pc = (alu_y & ~32'd1);
  end

  always_comb begin
    wb_data = alu_y;
    if (is_load)
      wb_data = fetched_r;
    else if (is_jal || is_jalr)
      wb_data = pc_r + 32'd4;
  end

  // Phase presented to the control unit.
  always_comb begin
    unique case (state)
      ST_DEC: phase = PHASE_DEC;
      ST_EX:  phase = PHASE_EX;
      ST_MEM_SETUP, ST_MEM_ACC: phase = PHASE_MEM;
      ST_WB:  phase = PHASE_WB;
      default: phase = PHASE_DEC;
    endcase
  end

  // ---------------------------------------------------------------------------
  // APB + sequential control
  // ---------------------------------------------------------------------------
  always_comb begin
    state_n     = state;
    pc_n        = pc_r;
    fetched_n   = fetched_r;
    step_n      = step_r;
    icount_n    = icount_r;
    PSEL        = 1'b0;
    PENABLE     = 1'b0;
    PWRITE      = 1'b0;
    PADDR       = 32'h0;
    PWDATA      = 32'h0;
    rf_we       = 1'b0;
    rf_waddr    = rd;
    rf_wdata    = wb_data;

    unique case (state)
      ST_IDLE: begin
        if (start) begin
          state_n  = ST_FETCH_SETUP;
          pc_n     = entry_pc;
          step_n   = 32'h0;
          icount_n = 32'h0;
        end
      end

      ST_FETCH_SETUP: begin
        PSEL    = 1'b1;
        PENABLE = 1'b0;
        PWRITE  = 1'b0;
        PADDR   = pc_r;
        state_n = ST_FETCH_ACC;
      end

      ST_FETCH_ACC: begin
        PSEL    = 1'b1;
        PENABLE = 1'b1;
        PWRITE  = 1'b0;
        PADDR   = pc_r;
        if (PREADY) begin
          state_n = ST_DEC;
        end
      end

      ST_DEC: begin
        state_n = ST_EX;
      end

      ST_EX: begin
        if (ctrl_illegal) begin
          state_n = ST_DONE;
        end else if (is_ebreak) begin
          state_n = ST_DONE;
        end else if (do_mem) begin
          state_n = ST_MEM_SETUP;
        end else begin
          state_n = ST_WB;
        end
      end

      ST_MEM_SETUP: begin
        PSEL    = 1'b1;
        PENABLE = 1'b0;
        PWRITE  = is_store;
        PADDR   = alu_y;
        PWDATA  = rs2_v;
        state_n = ST_MEM_ACC;
      end

      ST_MEM_ACC: begin
        PSEL    = 1'b1;
        PENABLE = 1'b1;
        PWRITE  = is_store;
        PADDR   = alu_y;
        PWDATA  = rs2_v;
        if (PREADY) begin
          if (is_load)
            fetched_n = PRDATA;
          state_n = ST_WB;
        end
      end

      ST_WB: begin
        if (ctrl_reg_write && !is_store)
          rf_we = 1'b1;
        rf_wdata = wb_data;
        state_n = ST_NEXT;
      end

      ST_NEXT: begin
        // Use PC captured before writeback so JALR rd==rs1 stays correct.
        pc_n     = next_pc_r;
        step_n   = step_r + 32'd1;
        icount_n = icount_r + 32'd1;
        if (step_r + 32'd1 >= step_limit)
          state_n = ST_DONE;
        else
          state_n = ST_FETCH_SETUP;
      end

      ST_DONE: begin
        state_n = ST_DONE;
      end

      default: state_n = ST_IDLE;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state     <= ST_IDLE;
      pc_r      <= 32'h0;
      instr_r   <= 32'h0;
      fetched_r <= 32'h0;
      next_pc_r <= 32'h0;
      step_r    <= 32'h0;
      icount_r  <= 32'h0;
      busy_r    <= 1'b0;
      done_r    <= 1'b0;
      trap_r    <= 1'b0;
    end else begin
      state     <= state_n;
      pc_r      <= pc_n;
      fetched_r <= fetched_n;
      step_r    <= step_n;
      icount_r  <= icount_n;

      if (state == ST_IDLE && start) begin
        busy_r <= 1'b1;
        done_r <= 1'b0;
        trap_r <= 1'b0;
      end

      if (state == ST_FETCH_ACC && PREADY)
        instr_r <= PRDATA;

      // Capture next PC during EX (before any regfile writeback).
      if (state == ST_EX && !ctrl_illegal && !is_ebreak)
        next_pc_r <= next_pc;

      if (state_n == ST_DONE && state != ST_DONE) begin
        busy_r <= 1'b0;
        done_r <= 1'b1;
        if (ctrl_illegal && !is_ebreak)
          trap_r <= 1'b1;
      end
    end
  end

  assign busy         = busy_r;
  assign done         = done_r;
  assign trap_illegal = trap_r;
  assign pc           = pc_r;
  assign fetched_data = fetched_r;
  assign instr_count  = icount_r;

  // Control fields decoded for completeness; mem_*/branch/jump/stall gate
  // the FSM via opcode classification rather than these wires directly.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ctrl_bits;
  assign unused_ctrl_bits = ctrl_mem_write | ctrl_mem_read | ctrl_branch
                          | ctrl_jump | ctrl[10] | (is_branch & alu_y[0]);
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
