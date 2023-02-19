`timescale 1ns / 1ns

module frame_sync #(
    parameter IN_DW = 32,
    localparam OUT_DW = IN_DW,
    localparam MAX_CP_LEN = 20
)
(
    input                                           clk_i,
    input                                           reset_ni,
    input   wire       [IN_DW - 1 : 0]              s_axis_in_tdata,
    input                                           s_axis_in_tvalid,

    input              [1 : 0]                      N_id_2_i,
    input                                           N_id_2_valid_i,
    input              [2 : 0]                      ibar_SSB_i,
    input                                           ibar_SSB_valid_i,

    output  reg        [1 : 0]                      PSS_detector_mode_o,
    output  reg        [1 : 0]                      requested_N_id_2_o,

    output  reg        [OUT_DW - 1 : 0]             m_axis_out_tdata,
    output  reg                                     m_axis_out_tvalid,
    output  reg        [$clog2(MAX_CP_LEN) - 1: 0]  CP_len_o,
    output  reg                                     symbol_start_o,
    output  reg                                     PBCH_start_o,
    output  reg                                     SSS_start_o
);

always @(posedge clk_i) begin
    if (!reset_ni) begin
        m_axis_out_tdata <= '0;
        m_axis_out_tvalid <= '0;
    end else begin
        m_axis_out_tdata <= s_axis_in_tdata;
        m_axis_out_tvalid <= s_axis_in_tvalid;
    end
end

always @(posedge clk_i) begin
    if (!reset_ni)  requested_N_id_2_o <= '0;
    else if (N_id_2_valid_i)  requested_N_id_2_o <= N_id_2_i;
end


// ---------------------------------------------------------------------------------------------------//
// FSM for controlling PSS detector
localparam [1 : 0] PSS_DETECTOR_MODE_SEARCH = 0;
localparam [1 : 0] PSS_DETECTOR_MODE_FIND   = 1;
localparam [1 : 0] PSS_DETECTOR_MODE_PAUSE  = 1;
localparam CLK_FREQ = 3840000;
localparam CLKS_20MS = $rtoi(CLK_FREQ * 0.02);
localparam CLKS_PSS_EARLY_WAKEUP = $rtoi(CLK_FREQ * 0.0001); // start PSS detector 0.1 ms before expected SSB
localparam CLKS_PSS_LATE_TOLERANCE = $rtoi(CLK_FREQ * 0.0001); // keep PSS detector running until 0.1ms after expected SSB
reg [$clog2(CLKS_20MS + CLKS_PSS_LATE_TOLERANCE) - 1 : 0] clks_since_SSB;
reg [1 : 0] PSS_state;
localparam [1 : 0] SEARCH_PSS = 0;
localparam [1 : 0] FIND_PSS = 1;
localparam [1 : 0] PAUSE_PSS = 2;
always @(posedge clk_i) begin
    if (!reset_ni) begin
        PSS_state <= SEARCH_PSS;
        clks_since_SSB <= '0;
    end else begin
        PSS_detector_mode_o <= PSS_state;
        case (PSS_state)
            SEARCH_PSS : begin  // search PSS with any N_id_2
                if (N_id_2_valid_i) begin
                    PSS_state <= PAUSE_PSS;
                    clks_since_SSB <= 1;
                end else begin
                    clks_since_SSB <= clks_since_SSB + 1;
                end
            end
            PAUSE_PSS : begin // PAUSE until next PSS is expected    
                if (clks_since_SSB > (CLKS_20MS - CLKS_PSS_EARLY_WAKEUP)) begin
                    PSS_state <= FIND_PSS;
                end else begin
                    clks_since_SSB <= clks_since_SSB + 1;
                end
            end
            FIND_PSS : begin  // FIND PSS with same N_id_2 as last one
                if (clks_since_SSB > (CLKS_20MS + CLKS_PSS_LATE_TOLERANCE)) begin
                    $display("did not find PSS, going back to SEARCH mode!");
                    PSS_state <= SEARCH_PSS;
                end else if (N_id_2_valid_i) begin
                    $display("found PSS in FIND mode, putting PSS detectore in PAUSE mode");
                    PSS_state <= PAUSE_PSS;
                    clks_since_SSB <= 1;
                end else begin
                    clks_since_SSB <= clks_since_SSB + 1;
                end
            end
        endcase
    end
end


// ---------------------------------------------------------------------------------------------------//
// FSM for keeping track of current subframe number and symbol number within a subframe 
// and sending the current CP length to the FFT_demod core
//
// sfn is the current subframe number
// sym_cnt is the current symbol number within the current subframe
//
// TODO: add timeout to WAIT_FOR_IBAR state
localparam SFN_MAX = 20;
localparam SYM_PER_SF = 14;
localparam FFT_LEN = 256;
localparam CP1_LEN = 20;
localparam CP2_LEN = 18;
reg [$clog2(SFN_MAX) -1 : 0] sfn;
reg [$clog2(2*SYM_PER_SF) - 1 : 0] sym_cnt;
reg [$clog2(2*SYM_PER_SF) - 1 : 0] expected_SSB_sym;
reg [$clog2(FFT_LEN + MAX_CP_LEN) - 1 : 0] SC_cnt;
reg [$clog2(MAX_CP_LEN) - 1 : 0] current_CP_len;
reg find_SSB;

localparam SYMS_BTWN_SSB = 14 * 20;
reg [$clog2(SYMS_BTWN_SSB) - 1 : 0] syms_to_next_SSB;

reg [1 : 0] state;
localparam [1 : 0] WAIT_FOR_SSB = 0;
localparam [1 : 0] WAIT_FOR_IBAR = 1;
localparam [1 : 0] SYNCED = 2;

always @(posedge clk_i) begin
    if (!reset_ni) begin
        sfn <= '0;
        sym_cnt = '0;
        SC_cnt <= '0;
        state <= WAIT_FOR_SSB;
        current_CP_len <= CP2_LEN;
        expected_SSB_sym <= '0;
        find_SSB <= '0;
        symbol_start_o <= '0;
        PBCH_start_o <= '0;
        SSS_start_o <= '0;
        syms_to_next_SSB <= '0;
        PSS_detector_mode_o <= PSS_DETECTOR_MODE_SEARCH;
    end else begin
        case (state)
            WAIT_FOR_SSB: begin
                PSS_detector_mode_o <= PSS_DETECTOR_MODE_SEARCH;
                if (N_id_2_valid_i) begin
                    SC_cnt <= 1;
                    // whether we are on symbol 3 or symbol 9 depends on ibar_SSB
                    // assume for now that we are at symbol 3
                    // it might have to be corrected once ibar_SSB arrives
                    current_CP_len <= CP2_LEN;
                    sym_cnt = 3;
                    expected_SSB_sym <= 3;
                    state <= WAIT_FOR_IBAR;
                    syms_to_next_SSB <= '0;
                    PBCH_start_o <= 1;
                end else begin
                    PBCH_start_o <= '0;
                end
            end
            WAIT_FOR_IBAR: begin
                PBCH_start_o <= '0;
                PSS_detector_mode_o <= PSS_DETECTOR_MODE_PAUSE;
                if (ibar_SSB_valid_i) begin
                    if (ibar_SSB_i != 0) begin
                        // sym_cnt needs to be corrected for ibar_SSB != 0
                        if (ibar_SSB_i == 1)        sym_cnt = sym_cnt + 6;
                        else if (ibar_SSB_i == 2)   sym_cnt = sym_cnt + 14;
                        else if (ibar_SSB_i == 3)   sym_cnt = sym_cnt + 20;

                        if (sym_cnt >= SYM_PER_SF) begin  // perform modulo SYM_PER_SF operation
                            sym_cnt = sym_cnt - SYM_PER_SF;
                        end
                    end
                    state <= SYNCED;
                end

                if (N_id_2_valid_i) $display("unexpected SSB_start in state 1 !");

                if (s_axis_in_tvalid) begin
                    if (SC_cnt == (FFT_LEN + current_CP_len - 1)) begin
                        sym_cnt = sym_cnt + 1;
                        if (sym_cnt >= SYM_PER_SF) begin  // perform modulo SYM_PER_SF operation
                            sym_cnt = sym_cnt - SYM_PER_SF;
                        end

                        SC_cnt <= '0;
                        if ((sym_cnt == 0) || (sym_cnt == 7))   current_CP_len <= CP1_LEN;
                        else                                    current_CP_len <= CP2_LEN;
                        syms_to_next_SSB <= syms_to_next_SSB + 1;                        
                    end else begin
                        SC_cnt <= SC_cnt + 1;
                    end
                end
            end
            SYNCED: begin  // synced
                PSS_detector_mode_o <= PSS_DETECTOR_MODE_PAUSE;
                if (ibar_SSB_valid_i) begin
                    // TODO throw error if ibar_SSB does not match expected ibar_SSB
                end

                if (find_SSB) begin
                    if (N_id_2_valid_i) begin
                        // expected SC_cnt is 0, if actual SC_cnt deviates +-1, perform realignment
                        if (SC_cnt == 0) begin
                            // SSB arrives as expected, no STO correction needed
                            $display("SSB is on time");
                        end else if (SC_cnt < 2) begin
                            // SSB arrives too late
                            // correct this STO by outputting symbol_start and PBCH_start a bit later
                            $display("SSB is late");
                        end else if (SC_cnt > (FFT_LEN + current_CP_len - 2)) begin
                            // SSB arrives too early
                            // correct this STO by outputting symbol_start and PBCH_start a bit earlier
                            $display("SSB is early");
                        end
                        find_SSB <= '0;
                    end

                    if (SC_cnt == 3) begin
                        // could not find SSB, connection is lost 
                        // go back to search mode (state 0)
                        $display("could not find SSB, connection is lost!");
                        find_SSB <= '0;
                        state <= WAIT_FOR_SSB;
                    end
                end else begin
                    if (N_id_2_valid_i) begin
                        $display("ignoring SSB");
                    end
                end

                if (N_id_2_valid_i && find_SSB)  PBCH_start_o <= '1;
                else                          PBCH_start_o <= '0;

                if (s_axis_in_tvalid) begin
                    if (SC_cnt == (FFT_LEN + current_CP_len - 1)) begin
                        sym_cnt = sym_cnt + 1;
                        if (sym_cnt >= SYM_PER_SF) begin  // perform modulo SYM_PER_SF operation
                            sym_cnt = sym_cnt - SYM_PER_SF;
                        end

                        SC_cnt <= '0;
                        if ((sym_cnt == 0) || (sym_cnt == 7))   current_CP_len <= CP1_LEN;
                        else                                    current_CP_len <= CP2_LEN;
                        syms_to_next_SSB <= syms_to_next_SSB + 1;
                    end else begin
                        SC_cnt <= SC_cnt + 1;
                    end

                    if ((SC_cnt == FFT_LEN + current_CP_len - 2) && (syms_to_next_SSB == (SYMS_BTWN_SSB - 1))) begin
                        find_SSB <= 1;
                        $display("find SSB ...");
                    end
                end
            end
        endcase
    end
end

endmodule