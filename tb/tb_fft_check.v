`timescale 1ns / 1ps
// ===========================================================================
// Self-checking unit test for fft_16pt_pipelined
// Compares every output bin with an ideal DFT (computed with real math)
// divided by 16, because the FFT core scales by 1/2 in each of its 4 stages.
// ===========================================================================
module tb_fft_check;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg signed [17:0] x [0:15];
    wire [35:0] bin_w [0:15];

    fft_16pt_pipelined dut (
        .clk(clk), .rst(rst), .start_i(1'b0),
        .in_0(x[0]),   .in_1(x[1]),   .in_2(x[2]),   .in_3(x[3]),
        .in_4(x[4]),   .in_5(x[5]),   .in_6(x[6]),   .in_7(x[7]),
        .in_8(x[8]),   .in_9(x[9]),   .in_10(x[10]), .in_11(x[11]),
        .in_12(x[12]), .in_13(x[13]), .in_14(x[14]), .in_15(x[15]),
        .bin_0(bin_w[0]),   .bin_1(bin_w[1]),   .bin_2(bin_w[2]),   .bin_3(bin_w[3]),
        .bin_4(bin_w[4]),   .bin_5(bin_w[5]),   .bin_6(bin_w[6]),   .bin_7(bin_w[7]),
        .bin_8(bin_w[8]),   .bin_9(bin_w[9]),   .bin_10(bin_w[10]), .bin_11(bin_w[11]),
        .bin_12(bin_w[12]), .bin_13(bin_w[13]), .bin_14(bin_w[14]), .bin_15(bin_w[15])
    );

    localparam real PI  = 3.14159265358979;
    localparam real TOL = 4.0;          // allowed error in LSB

    integer n, k, test_fails, total_fails;
    real ang, ref_re, ref_im, err_re, err_im, max_err;

    // Run one test: wait for the pipeline, then compare all 16 bins
    task check;
        input [8*16-1:0] name;
        begin
            repeat (6) @(posedge clk);
            #1;
            max_err = 0.0;
            for (k = 0; k < 16; k = k + 1) begin
                ref_re = 0.0; ref_im = 0.0;
                for (n = 0; n < 16; n = n + 1) begin
                    ang    = -2.0 * PI * k * n / 16.0;
                    ref_re = ref_re + $itor(x[n]) * $cos(ang);
                    ref_im = ref_im + $itor(x[n]) * $sin(ang);
                end
                ref_re = ref_re / 16.0;
                ref_im = ref_im / 16.0;
                err_re = $itor($signed(bin_w[k][35:18])) - ref_re;
                err_im = $itor($signed(bin_w[k][17:0]))  - ref_im;
                if (err_re < 0.0) err_re = -err_re;
                if (err_im < 0.0) err_im = -err_im;
                if (err_re > max_err) max_err = err_re;
                if (err_im > max_err) max_err = err_im;
            end
            if (max_err <= TOL) $display("PASS  %0s  (max error %0.1f LSB)", name, max_err);
            else begin
                $display("FAIL  %0s  (max error %0.1f LSB)", name, max_err);
                total_fails = total_fails + 1;
            end
        end
    endtask

    integer seed;
    initial begin
        total_fails = 0; seed = 7;
        for (n = 0; n < 16; n = n + 1) x[n] = 0;
        #25 rst = 0;
        $display("---------------------------------------------------");
        $display("FFT UNIT TEST (ideal DFT / 16 as reference)");
        $display("---------------------------------------------------");

        for (n = 0; n < 16; n = n + 1) x[n] = $rtoi(8000.0 * $cos(2.0*PI*2.0*n/16.0));
        check("tone at bin 2");

        for (n = 0; n < 16; n = n + 1) x[n] = 5000;
        check("DC level");

        for (n = 0; n < 16; n = n + 1) x[n] = $rtoi(12000.0 * $cos(2.0*PI*4.0*n/16.0 + 0.7));
        check("tone at bin 4");

        for (n = 0; n < 16; n = n + 1) x[n] = ($random(seed) % 15000);
        check("random data");

        for (n = 0; n < 16; n = n + 1)
            x[n] = $rtoi(10000.0*$sin(2.0*PI*3.0*n/16.0) + 3000.0*$cos(2.0*PI*7.0*n/16.0) + 2000.0);
        check("two tones + DC");

        for (n = 0; n < 16; n = n + 1) x[n] = 0;
        x[0] = 20000;
        check("impulse");

        $display("---------------------------------------------------");
        if (total_fails == 0) $display("FFT CHECK PASSED: all tests within %0.0f LSB", TOL);
        else                  $display("FFT CHECK FAILED: %0d test(s) out of tolerance", total_fails);
        $display("---------------------------------------------------");
        $finish;
    end
endmodule
