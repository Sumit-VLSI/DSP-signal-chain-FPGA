`timescale 1ns / 1ps

module signal_generation_top (
    input wire clk,               // System Clock: 100 MHz
    input wire rst               // Active High Synchronous Reset
);

    (* mark_debug = "true" *) wire signed [17:0] filter_output;  // Final filtered signal
    (* mark_debug = "true" *) wire filter_out_valid;              // Final filtered signal valid flag
    // ========================================================================
    // 1. PHASE & SINE GENERATION (CORDIC)
    // ========================================================================
    reg signed [15:0] phase_2mhz, phase_15mhz, phase_25mhz, phase_30mhz;
    reg phase_valid;

    localparam signed [16:0] PI_POS = 17'sd25736; 
    localparam signed [16:0] PI_NEG = -17'sd25736; 

    localparam signed [16:0] PHASE_INC_2MHZ  = 17'sd1029;
    localparam signed [16:0] PHASE_INC_15MHZ = 17'sd7721;
    localparam signed [16:0] PHASE_INC_25MHZ = 17'sd12868;
    localparam signed [16:0] PHASE_INC_30MHZ = 17'sd15442;

    always @(posedge clk) begin
        if (rst) begin
            phase_2mhz  <= 16'sd0; phase_15mhz <= 16'sd0;
            phase_25mhz <= 16'sd0; phase_30mhz <= 16'sd0;
            phase_valid <= 1'b0;
        end else begin
            phase_valid <= 1'b1;
            if (phase_2mhz + PHASE_INC_2MHZ <= PI_POS) phase_2mhz <= phase_2mhz + PHASE_INC_2MHZ;
            else phase_2mhz <= PI_NEG + (phase_2mhz + PHASE_INC_2MHZ - PI_POS);

            if (phase_15mhz + PHASE_INC_15MHZ <= PI_POS) phase_15mhz <= phase_15mhz + PHASE_INC_15MHZ;
            else phase_15mhz <= PI_NEG + (phase_15mhz + PHASE_INC_15MHZ - PI_POS);

            if (phase_25mhz + PHASE_INC_25MHZ <= PI_POS) phase_25mhz <= phase_25mhz + PHASE_INC_25MHZ;
            else phase_25mhz <= PI_NEG + (phase_25mhz + PHASE_INC_25MHZ - PI_POS);

            if (phase_30mhz + PHASE_INC_30MHZ <= PI_POS) phase_30mhz <= phase_30mhz + PHASE_INC_30MHZ;
            else phase_30mhz <= PI_NEG + (phase_30mhz + PHASE_INC_30MHZ - PI_POS);
        end
    end

    wire [31:0] cordic_out_2mhz, cordic_out_15mhz, cordic_out_25mhz, cordic_out_30mhz;
    wire valid_2mhz, valid_15mhz, valid_25mhz, valid_30mhz;

    (* mark_debug = "true" *) wire signed [15:0] sine_2mhz  = cordic_out_2mhz[31:16];
    (* mark_debug = "true" *) wire signed [15:0] sine_15mhz = cordic_out_15mhz[31:16];
    (* mark_debug = "true" *) wire signed [15:0] sine_25mhz = cordic_out_25mhz[31:16];
    (* mark_debug = "true" *) wire signed [15:0] sine_30mhz = cordic_out_30mhz[31:16];

    cordic_0 cordic_2mhz_inst (.aclk(clk), .s_axis_phase_tvalid(phase_valid), .s_axis_phase_tdata(phase_2mhz), .m_axis_dout_tvalid(valid_2mhz), .m_axis_dout_tdata(cordic_out_2mhz));
    cordic_0 cordic_15mhz_inst (.aclk(clk), .s_axis_phase_tvalid(phase_valid), .s_axis_phase_tdata(phase_15mhz), .m_axis_dout_tvalid(valid_15mhz), .m_axis_dout_tdata(cordic_out_15mhz));
    cordic_0 cordic_25mhz_inst (.aclk(clk), .s_axis_phase_tvalid(phase_valid), .s_axis_phase_tdata(phase_25mhz), .m_axis_dout_tvalid(valid_25mhz), .m_axis_dout_tdata(cordic_out_25mhz));
    cordic_0 cordic_30mhz_inst (.aclk(clk), .s_axis_phase_tvalid(phase_valid), .s_axis_phase_tdata(phase_30mhz), .m_axis_dout_tvalid(valid_30mhz), .m_axis_dout_tdata(cordic_out_30mhz));

    // ========================================================================
    // 2. PIPELINED MIXER
    // ========================================================================
    (* mark_debug = "true" *) reg signed [17:0] mixed_signal;
    reg mixed_valid;
    
    reg signed [16:0] mix_sum1, mix_sum2;
    reg mix_valid_stage1;
    wire all_cordics_valid = valid_2mhz & valid_15mhz & valid_25mhz & valid_30mhz;

    always @(posedge clk) begin
        if (rst) begin
            mix_sum1 <= 17'sd0; mix_sum2 <= 17'sd0; mixed_signal <= 18'sd0;
            mix_valid_stage1 <= 1'b0; mixed_valid <= 1'b0;
        end else begin
            mix_sum1 <= sine_2mhz + sine_15mhz;
            mix_sum2 <= sine_25mhz + sine_30mhz;
            mix_valid_stage1 <= all_cordics_valid;

            mixed_signal <= mix_sum1 + mix_sum2;
            mixed_valid  <= mix_valid_stage1;
        end
    end

    // ========================================================================
    // 3. FIR FILTER
    // ========================================================================
    fir_9tap_lpf filter_inst (
        .clk(clk),
        .rst(rst),
        .data_in(mixed_signal),
        .data_in_valid(mixed_valid),
        .data_out(filter_output),
        .data_out_valid(filter_out_valid)
    );

    // ========================================================================
    // 4. FROM-SCRATCH 16-POINT FFT DATA COLLECTOR
    // ========================================================================
    reg signed [17:0] fft_input_buffer [0:15];
    reg [3:0] sample_count;
    reg fft_trigger;
    integer k;

    // Stream-to-Block Shift Accumulator
    always @(posedge clk) begin
        if (rst) begin
            sample_count <= 4'd0;
            fft_trigger  <= 1'b0;
            for (k = 0; k < 16; k = k + 1) fft_input_buffer[k] <= 18'sd0;
        end else begin
            fft_trigger <= 1'b0;
            if (filter_out_valid) begin
                fft_input_buffer[sample_count] <= filter_output;
                sample_count <= sample_count + 1;
                if (sample_count == 4'd15) begin
                    fft_trigger <= 1'b1; // Pulse high when block is full
                end
            end
        end
    end

    // Parallel Bin Outputs from From-Scratch FFT Engine
    (* mark_debug = "true" *) wire [35:0] bin_0, bin_1, bin_2, bin_3, bin_4, bin_5, bin_6, bin_7;
    (* mark_debug = "true" *) wire [35:0] bin_8, bin_9, bin_10, bin_11, bin_12, bin_13, bin_14, bin_15;

    fft_16pt_pipelined fft_core_inst (
        .clk(clk), .rst(rst), .start_i(fft_trigger),
        .in_0(fft_input_buffer[0]),   .in_1(fft_input_buffer[1]),
        .in_2(fft_input_buffer[2]),   .in_3(fft_input_buffer[3]),
        .in_4(fft_input_buffer[4]),   .in_5(fft_input_buffer[5]),
        .in_6(fft_input_buffer[6]),   .in_7(fft_input_buffer[7]),
        .in_8(fft_input_buffer[8]),   .in_9(fft_input_buffer[9]),
        .in_10(fft_input_buffer[10]), .in_11(fft_input_buffer[11]),
        .in_12(fft_input_buffer[12]), .in_13(fft_input_buffer[13]),
        .in_14(fft_input_buffer[14]), .in_15(fft_input_buffer[15]),
        .bin_0(bin_0),   .bin_1(bin_1),   .bin_2(bin_2),   .bin_3(bin_3),
        .bin_4(bin_4),   .bin_5(bin_5),   .bin_6(bin_6),   .bin_7(bin_7),
        .bin_8(bin_8),   .bin_9(bin_9),   .bin_10(bin_10), .bin_11(bin_11),
        .bin_12(bin_12), .bin_13(bin_13), .bin_14(bin_14), .bin_15(bin_15)
    );

    // ========================================================================
    // 5. INTEGRATED LOGIC ANALYZER (ILA) - REDUCED PROBES
    // ========================================================================
    ila_0 your_ila_inst (
        .clk(clk),                  // 1-bit
        .probe0(rst),               // 1-bit
        .probe1(sine_2mhz),         // 16-bit
        .probe2(sine_15mhz),        // 16-bit
        .probe3(sine_25mhz),        // 16-bit
        .probe4(sine_30mhz),        // 16-bit
        .probe5(mixed_signal),      // 18-bit
        .probe6(filter_output),     // 18-bit
        .probe7(bin_0),             // 36-bit (DC)
        .probe8(bin_1),             // 36-bit (Positive Freq)
        .probe9(bin_2),             // 36-bit (Positive Freq)
        .probe10(bin_3),            // 36-bit (Positive Freq)
        .probe11(bin_4),            // 36-bit (Positive Freq)
        .probe12(bin_5),            // 36-bit (Positive Freq)
        .probe13(bin_6),            // 36-bit (Positive Freq)
        .probe14(bin_7),            // 36-bit (Positive Freq)
        .probe15(bin_8[35:18])             // 36-bit (Nyquist)
    );

endmodule

// ========================================================================
// HAND-CRAFTED 16-POINT PIPELINED PARALLEL FFT MODULE
// ========================================================================
module fft_16pt_pipelined (
    input wire clk,
    input wire rst,
    input wire start_i,
    input wire signed [17:0] in_0,  input wire signed [17:0] in_1,
    input wire signed [17:0] in_2,  input wire signed [17:0] in_3,
    input wire signed [17:0] in_4,  input wire signed [17:0] in_5,
    input wire signed [17:0] in_6,  input wire signed [17:0] in_7,
    input wire signed [17:0] in_8,  input wire signed [17:0] in_9,
    input wire signed [17:0] in_10, input wire signed [17:0] in_11,
    input wire signed [17:0] in_12, input wire signed [17:0] in_13,
    input wire signed [17:0] in_14, input wire signed [17:0] in_15,
    
    // Outputs pack Real component on [35:18] and Imaginary component on [17:0]
    output wire [35:0] bin_0,  output wire [35:0] bin_1,
    output wire [35:0] bin_2,  output wire [35:0] bin_3,
    output wire [35:0] bin_4,  output wire [35:0] bin_5,
    output wire [35:0] bin_6,  output wire [35:0] bin_7,
    output wire [35:0] bin_8,  output wire [35:0] bin_9,
    output wire [35:0] bin_10, output wire [35:0] bin_11,
    output wire [35:0] bin_12, output wire [35:0] bin_13,
    output wire [35:0] bin_14, output wire [35:0] bin_15
);

    // Q15 Twiddle Factors W_16^k = cos(2*pi*k/16) - j*sin(2*pi*k/16)
    // format: 16-bit signed integer (1.0 = 32767)
    localparam signed [15:0] WR0 = 16'sd32767, WI0 = 16'sd0;
    localparam signed [15:0] WR1 = 16'sd30273, WI1 = -16'sd12539;
    localparam signed [15:0] WR2 = 16'sd23170, WI2 = -16'sd23170;
    localparam signed [15:0] WR3 = 16'sd12539, WI3 = -16'sd30273;
    localparam signed [15:0] WR4 = 16'sd0,     WI4 = -16'sd32768;
    localparam signed [15:0] WR5 = -16'sd12539,WI5 = -16'sd30273;
    localparam signed [15:0] WR6 = -16'sd23170,WI6 = -16'sd23170;
    localparam signed [15:0] WR7 = -16'sd30273,WI7 = -16'sd12539;

    // Inter-stage pipeline array nodes
    reg signed [17:0] s1_r[0:15], s1_i[0:15];
    reg signed [17:0] s2_r[0:15], s2_i[0:15];
    reg signed [17:0] s3_r[0:15], s3_i[0:15];
    reg signed [17:0] s4_r[0:15], s4_i[0:15];

    // Functional temporary wires to avoid code bloating
    reg signed [18:0] diff_r, diff_i;
    reg signed [34:0] prod_rr, prod_ri, prod_ir, prod_ii;
    integer m;

    always @(posedge clk) begin
        if (rst) begin
            for(m=0; m<16; m=m+1) begin
                s1_r[m] <= 18'sd0; s1_i[m] <= 18'sd0;
                s2_r[m] <= 18'sd0; s2_i[m] <= 18'sd0;
                s3_r[m] <= 18'sd0; s3_i[m] <= 18'sd0;
                s4_r[m] <= 18'sd0; s4_i[m] <= 18'sd0;
            end
        end else begin
            // -------------------------------------------------------------
            // STAGE 1 (Distance = 8)
            // -------------------------------------------------------------
            // Top Halves
            s1_r[0] <= (in_0 + in_8)   >>> 1; s1_i[0] <= 18'sd0;
            s1_r[1] <= (in_1 + in_9)   >>> 1; s1_i[1] <= 18'sd0;
            s1_r[2] <= (in_2 + in_10)  >>> 1; s1_i[2] <= 18'sd0;
            s1_r[3] <= (in_3 + in_11)  >>> 1; s1_i[3] <= 18'sd0;
            s1_r[4] <= (in_4 + in_12)  >>> 1; s1_i[4] <= 18'sd0;
            s1_r[5] <= (in_5 + in_13)  >>> 1; s1_i[5] <= 18'sd0;
            s1_r[6] <= (in_6 + in_14)  >>> 1; s1_i[6] <= 18'sd0;
            s1_r[7] <= (in_7 + in_15)  >>> 1; s1_i[7] <= 18'sd0;
            // Bottom Halves (Multiplied by W_16^k)
            s1_r[8]  <= ((in_0 - in_8)*WR0)   >>> 16; s1_i[8]  <= ((in_0 - in_8)*WI0)   >>> 16;
            s1_r[9]  <= ((in_1 - in_9)*WR1)   >>> 16; s1_i[9]  <= ((in_1 - in_9)*WI1)   >>> 16;
            s1_r[10] <= ((in_2 - in_10)*WR2)  >>> 16; s1_i[10] <= ((in_2 - in_10)*WI2)  >>> 16;
            s1_r[11] <= ((in_3 - in_11)*WR3)  >>> 16; s1_i[11] <= ((in_3 - in_11)*WI3)  >>> 16;
            s1_r[12] <= ((in_4 - in_12)*WR4)  >>> 16; s1_i[12] <= ((in_4 - in_12)*WI4)  >>> 16;
            s1_r[13] <= ((in_5 - in_13)*WR5)  >>> 16; s1_i[13] <= ((in_5 - in_13)*WI5)  >>> 16;
            s1_r[14] <= ((in_6 - in_14)*WR6)  >>> 16; s1_i[14] <= ((in_6 - in_14)*WI6)  >>> 16;
            s1_r[15] <= ((in_7 - in_15)*WR7)  >>> 16; s1_i[15] <= ((in_7 - in_15)*WI7)  >>> 16;

            // -------------------------------------------------------------
            // STAGE 2 (Distance = 4)
            // -------------------------------------------------------------
            // Group 0
            s2_r[0] <= (s1_r[0] + s1_r[4]) >>> 1; s2_i[0] <= (s1_i[0] + s1_i[4]) >>> 1;
            s2_r[1] <= (s1_r[1] + s1_r[5]) >>> 1; s2_i[1] <= (s1_i[1] + s1_i[5]) >>> 1;
            s2_r[2] <= (s1_r[2] + s1_r[6]) >>> 1; s2_i[2] <= (s1_i[2] + s1_i[6]) >>> 1;
            s2_r[3] <= (s1_r[3] + s1_r[7]) >>> 1; s2_i[3] <= (s1_i[3] + s1_i[7]) >>> 1;
            
            s2_r[4] <= (((s1_r[0]-s1_r[4])*WR0) - ((s1_i[0]-s1_i[4])*WI0)) >>> 16;
            s2_i[4] <= (((s1_r[0]-s1_r[4])*WI0) + ((s1_i[0]-s1_i[4])*WR0)) >>> 16;
            s2_r[5] <= (((s1_r[1]-s1_r[5])*WR2) - ((s1_i[1]-s1_i[5])*WI2)) >>> 16;
            s2_i[5] <= (((s1_r[1]-s1_r[5])*WI2) + ((s1_i[1]-s1_i[5])*WR2)) >>> 16;
            s2_r[6] <= (((s1_r[2]-s1_r[6])*WR4) - ((s1_i[2]-s1_i[6])*WI4)) >>> 16;
            s2_i[6] <= (((s1_r[2]-s1_r[6])*WI4) + ((s1_i[2]-s1_i[6])*WR4)) >>> 16;
            s2_r[7] <= (((s1_r[3]-s1_r[7])*WR6) - ((s1_i[3]-s1_i[7])*WI6)) >>> 16;
            s2_i[7] <= (((s1_r[3]-s1_r[7])*WI6) + ((s1_i[3]-s1_i[7])*WR6)) >>> 16;

            // Group 1
            s2_r[8]  <= (s1_r[8]  + s1_r[12]) >>> 1; s2_i[8]  <= (s1_i[8]  + s1_i[12]) >>> 1;
            s2_r[9]  <= (s1_r[9]  + s1_r[13]) >>> 1; s2_i[9]  <= (s1_i[9]  + s1_i[13]) >>> 1;
            s2_r[10] <= (s1_r[10] + s1_r[14]) >>> 1; s2_i[10] <= (s1_i[10] + s1_i[14]) >>> 1;
            s2_r[11] <= (s1_r[11] + s1_r[15]) >>> 1; s2_i[11] <= (s1_i[11] + s1_i[15]) >>> 1;
            
            s2_r[12] <= (((s1_r[8]-s1_r[12])*WR0) - ((s1_i[8]-s1_i[12])*WI0)) >>> 16;
            s2_i[12] <= (((s1_r[8]-s1_r[12])*WI0) + ((s1_i[8]-s1_i[12])*WR0)) >>> 16;
            s2_r[13] <= (((s1_r[9]-s1_r[13])*WR2) - ((s1_i[9]-s1_i[13])*WI2)) >>> 16;
            s2_i[13] <= (((s1_r[9]-s1_r[13])*WI2) + ((s1_i[9]-s1_i[13])*WR2)) >>> 16;
            s2_r[14] <= (((s1_r[10]-s1_r[14])*WR4) - ((s1_i[10]-s1_i[14])*WI4)) >>> 16;
            s2_i[14] <= (((s1_r[10]-s1_r[14])*WI4) + ((s1_i[10]-s1_r[14])*WR4)) >>> 16;
            s2_r[15] <= (((s1_r[11]-s1_r[15])*WR6) - ((s1_i[11]-s1_i[15])*WI6)) >>> 16;
            s2_i[15] <= (((s1_r[11]-s1_r[15])*WI6) + ((s1_i[11]-s1_i[15])*WR6)) >>> 16;

            // -------------------------------------------------------------
            // STAGE 3 (Distance = 2)
            // -------------------------------------------------------------
            // Processed with precomputed sets for structural loop clarity 
            s3_r[0]  <= (s2_r[0]  + s2_r[2])  >>> 1; s3_i[0]  <= (s2_i[0]  + s2_i[2])  >>> 1;
            s3_r[1]  <= (s2_r[1]  + s2_r[3])  >>> 1; s3_i[1]  <= (s2_i[1]  + s2_i[3])  >>> 1;
            s3_r[2]  <= (((s2_r[0]-s2_r[2])*WR0)  - ((s2_i[0]-s2_i[2])*WI0))  >>> 16;
            s3_i[2]  <= (((s2_r[0]-s2_r[2])*WI0)  + ((s2_i[0]-s2_i[2])*WR0))  >>> 16;
            s3_r[3]  <= (((s2_r[1]-s2_r[3])*WR4)  - ((s2_i[1]-s2_i[3])*WI4))  >>> 16;
            s3_i[3]  <= (((s2_r[1]-s2_r[3])*WI4)  + ((s2_i[1]-s2_i[3])*WR4))  >>> 16;

            s3_r[4]  <= (s2_r[4]  + s2_r[6])  >>> 1; s3_i[4]  <= (s2_i[4]  + s2_i[6])  >>> 1;
            s3_r[5]  <= (s2_r[5]  + s2_r[7])  >>> 1; s3_i[5]  <= (s2_i[5]  + s2_i[7])  >>> 1;
            s3_r[6]  <= (((s2_r[4]-s2_r[6])*WR0)  - ((s2_i[4]-s2_i[6])*WI0))  >>> 16;
            s3_i[6]  <= (((s2_r[4]-s2_r[6])*WI0)  + ((s2_i[4]-s2_i[6])*WR0))  >>> 16;
            s3_r[7]  <= (((s2_r[5]-s2_r[7])*WR4)  - ((s2_i[5]-s2_i[7])*WI4))  >>> 16;
            s3_i[7]  <= (((s2_r[5]-s2_r[7])*WI4)  + ((s2_i[5]-s2_i[7])*WR4))  >>> 16;

            s3_r[8]  <= (s2_r[8]  + s2_r[10]) >>> 1; s3_i[8]  <= (s2_i[8]  + s2_i[10]) >>> 1;
            s3_r[9]  <= (s2_r[9]  + s2_r[11]) >>> 1; s3_i[9]  <= (s2_i[9]  + s2_i[11]) >>> 1;
            s3_r[10] <= (((s2_r[8]-s2_r[10])*WR0) - ((s2_i[8]-s2_i[10])*WI0)) >>> 16;
            s3_i[10] <= (((s2_r[8]-s2_r[10])*WI0) + ((s2_i[8]-s2_i[10])*WR0)) >>> 16;
            s3_r[11] <= (((s2_r[9]-s2_r[11])*WR4) - ((s2_i[9]-s2_i[11])*WI4)) >>> 16;
            s3_i[11] <= (((s2_r[9]-s2_r[11])*WI4) + ((s2_i[9]-s2_i[11])*WR4)) >>> 16;

            s3_r[12] <= (s2_r[12] + s2_r[14]) >>> 1; s3_i[12] <= (s2_i[12] + s2_i[14]) >>> 1;
            s3_r[13] <= (s2_r[13] + s2_r[11]) >>> 1; s3_i[13] <= (s2_i[13] + s2_i[15]) >>> 1;
            s3_r[14] <= (((s2_r[12]-s2_r[14])*WR0) - ((s2_i[12]-s2_i[14])*WI0)) >>> 16;
            s3_i[14] <= (((s2_r[12]-s2_r[14])*WI0) + ((s2_i[12]-s2_i[14])*WR0)) >>> 16;
            s3_r[15] <= (((s2_r[13]-s2_r[15])*WR4) - ((s2_i[13]-s2_i[15])*WI4)) >>> 16;
            s3_i[15] <= (((s2_r[13]-s2_r[15])*WI4) + ((s2_i[13]-s2_i[15])*WR4)) >>> 16;

            // -------------------------------------------------------------
            // STAGE 4 (Distance = 1)
            // -------------------------------------------------------------
            // Twiddle factors are W^0 = 1, meaning we drop multipliers here entirely
            s4_r[0]  <= (s3_r[0]  + s3_r[1])  >>> 1; s4_i[0]  <= (s3_i[0]  + s3_i[1])  >>> 1;
            s4_r[1]  <= (s3_r[0]  - s3_r[1])  >>> 1; s4_i[1]  <= (s3_i[0]  - s3_i[1])  >>> 1;
            s4_r[2]  <= (s3_r[2]  + s3_r[3])  >>> 1; s4_i[2]  <= (s3_i[2]  + s3_i[3])  >>> 1;
            s4_r[3]  <= (s3_r[2]  - s3_r[3])  >>> 1; s4_i[3]  <= (s3_i[2]  - s3_i[3])  >>> 1;
            s4_r[4]  <= (s3_r[4]  + s3_r[5])  >>> 1; s4_i[4]  <= (s3_i[4]  + s3_i[5])  >>> 1;
            s4_r[5]  <= (s3_r[4]  - s3_r[5])  >>> 1; s4_i[5]  <= (s3_i[4]  - s3_i[5])  >>> 1;
            s4_r[6]  <= (s3_r[6]  + s3_r[7])  >>> 1; s4_i[6]  <= (s3_i[6]  + s3_i[7])  >>> 1;
            s4_r[7]  <= (s3_r[6]  - s3_r[7])  >>> 1; s4_i[7]  <= (s3_i[6]  - s3_i[7])  >>> 1;
            s4_r[8]  <= (s3_r[8]  + s3_r[9])  >>> 1; s4_i[8]  <= (s3_i[8]  + s3_i[9])  >>> 1;
            s4_r[9]  <= (s3_r[8]  - s3_r[9])  >>> 1; s4_i[9]  <= (s3_i[8]  - s3_i[9])  >>> 1;
            s4_r[10] <= (s3_r[10] + s3_r[11]) >>> 1; s4_i[10] <= (s3_i[10] + s3_i[11]) >>> 1;
            s4_r[11] <= (s3_r[10] - s3_r[11]) >>> 1; s4_i[11] <= (s3_i[10] - s3_i[11]) >>> 1;
            s4_r[12] <= (s3_r[12] + s3_r[13]) >>> 1; s4_i[12] <= (s3_i[12] + s3_i[13]) >>> 1;
            s4_r[13] <= (s3_r[12] - s3_r[13]) >>> 1; s4_i[13] <= (s3_i[12] - s3_i[13]) >>> 1;
            s4_r[14] <= (s3_r[14] + s3_r[15]) >>> 1; s4_i[14] <= (s3_i[14] + s3_i[15]) >>> 1;
            s4_r[15] <= (s3_r[14] - s3_r[15]) >>> 1; s4_i[15] <= (s3_i[14] - s3_i[15]) >>> 1;
        end
    end

    // -------------------------------------------------------------
    // NATURAL RE-MAPPING VIA BIT REVERSAL
    // -------------------------------------------------------------
    assign bin_0  = {s4_r[0],  s4_i[0]};
    assign bin_1  = {s4_r[8],  s4_i[8]};
    assign bin_2  = {s4_r[4],  s4_i[4]};
    assign bin_3  = {s4_r[12], s4_i[12]};
    assign bin_4  = {s4_r[2],  s4_i[2]};
    assign bin_5  = {s4_r[10], s4_i[10]};
    assign bin_6  = {s4_r[6],  s4_i[6]};
    assign bin_7  = {s4_r[14], s4_i[14]};
    assign bin_8  = {s4_r[1],  s4_i[1]};
    assign bin_9  = {s4_r[9],  s4_i[9]};
    assign bin_10 = {s4_r[5],  s4_i[5]};
    assign bin_11 = {s4_r[13], s4_i[13]};
    assign bin_12 = {s4_r[3],  s4_i[3]};
    assign bin_13 = {s4_r[11], s4_i[11]};
    assign bin_14 = {s4_r[7],  s4_i[7]};
    assign bin_15 = {s4_r[15], s4_i[15]};

endmodule

// ========================================================================
// FIR FILTER WITH 6-STAGE PIPELINE (TIMING SECURED)
// ========================================================================
module fir_9tap_lpf (
    input wire clk,
    input wire rst,
    input wire signed [17:0] data_in,      
    input wire data_in_valid,              
    output reg signed [17:0] data_out,     
    output reg data_out_valid              
);

    localparam signed [15:0] H0 = 16'd1533; localparam signed [15:0] H1 = 16'd3307;
    localparam signed [15:0] H2 = 16'd4960; localparam signed [15:0] H3 = 16'd6131;
    localparam signed [15:0] H4 = 16'd6554; localparam signed [15:0] H5 = 16'd6131;
    localparam signed [15:0] H6 = 16'd4960; localparam signed [15:0] H7 = 16'd3307;
    localparam signed [15:0] H8 = 16'd1533;

    reg signed [17:0] shift_reg [0:8];
    reg signed [33:0] product [0:8];
    reg signed [34:0] sum_lvl1_0, sum_lvl1_1, sum_lvl1_2, sum_lvl1_3, sum_lvl1_4;
    reg signed [35:0] sum_lvl2_0, sum_lvl2_1, sum_lvl2_2;
    reg signed [37:0] accumulator;
    
    reg [5:0] valid_pipe;
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 9; i = i + 1) begin
                shift_reg[i] <= 18'sd0; product[i] <= 34'sd0;
            end
            accumulator <= 38'sd0; data_out <= 18'sd0;
            valid_pipe <= 6'd0; data_out_valid <= 1'b0;
            sum_lvl1_0 <= 35'sd0; sum_lvl1_1 <= 35'sd0; sum_lvl1_2 <= 35'sd0;
            sum_lvl1_3 <= 35'sd0; sum_lvl1_4 <= 35'sd0;
            sum_lvl2_0 <= 36'sd0; sum_lvl2_1 <= 36'sd0; sum_lvl2_2 <= 36'sd0;
        end else begin
            valid_pipe[0] <= data_in_valid;
            valid_pipe[1] <= valid_pipe[0];
            valid_pipe[2] <= valid_pipe[1];
            valid_pipe[3] <= valid_pipe[2];
            valid_pipe[4] <= valid_pipe[3];
            valid_pipe[5] <= valid_pipe[4];
            data_out_valid <= valid_pipe[5];

            shift_reg[0] <= data_in_valid ? data_in : 18'sd0;
            for (i = 1; i < 9; i = i + 1) shift_reg[i] <= shift_reg[i-1];
            
            product[0] <= shift_reg[0] * H0; product[1] <= shift_reg[1] * H1;
            product[2] <= shift_reg[2] * H2; product[3] <= shift_reg[3] * H3;
            product[4] <= shift_reg[4] * H4; product[5] <= shift_reg[5] * H5;
            product[6] <= shift_reg[6] * H6; product[7] <= shift_reg[7] * H7;
            product[8] <= shift_reg[8] * H8;

            sum_lvl1_0 <= product[0] + product[1]; sum_lvl1_1 <= product[2] + product[3];
            sum_lvl1_2 <= product[4] + product[5]; sum_lvl1_3 <= product[6] + product[7];
            sum_lvl1_4 <= product[8];

            sum_lvl2_0 <= sum_lvl1_0 + sum_lvl1_1; sum_lvl2_1 <= sum_lvl1_2 + sum_lvl1_3;
            sum_lvl2_2 <= sum_lvl1_4;

            accumulator <= sum_lvl2_0 + sum_lvl2_1 + sum_lvl2_2;
            data_out <= accumulator[32:15];
        end
    end
endmodule
