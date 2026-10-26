# Design, Development and Implementation of DSP Modules on FPGA

A complete **digital signal processing chain in Verilog**, implemented on a **Digilent Arty Z7** FPGA board and verified live with the **Xilinx Integrated Logic Analyzer (ILA)**. Four sine waves are generated, mixed, low-pass filtered, and analysed with a hand-written pipelined 16-point FFT.

*Developed during an internship at Aujus Technology.*

<img width="1280" height="963" alt="WhatsApp Image 2026-10-26 at 2 21 00 PM" src="https://github.com/user-attachments/assets/044ddf08-30a1-4b54-9353-759db219b8d2" />


---

## What the Design Does

1. **Generates four sine waves** (2, 15, 25 and 30 MHz at a 100 MHz sample rate) using phase accumulators (DDS) feeding the **Xilinx CORDIC IP**
2. **Mixes** the four sines through a pipelined adder tree
3. **Filters** the composite signal with a custom **9-tap low-pass FIR filter**
4. **Collects 16 filtered samples** and runs a custom **pipelined 16-point FFT**
5. **Validates** every stage on hardware with the ILA

---

## Architecture

<img width="2400" height="1320" alt="dsp_architecture" src="https://github.com/user-attachments/assets/c6c7cbf7-25fe-41d7-9129-3efdd23310bc" />


| Stage | Module | Width | Notes |
|-------|--------|-------|-------|
| Phase accumulators | `signal_generation_top` | 16-bit phase | One accumulator per tone, wraps at ±π |
| Sine generation | `cordic_0` (Xilinx IP) x 4 | 16-bit sine | Sine taken from `m_axis_dout_tdata[31:16]` |
| Mixer | `signal_generation_top` | 17-bit, then 18-bit | Two-stage pipelined adder tree |
| Low-pass filter | `fir_9tap_lpf` | 18-bit in / out | 6-stage pipeline, Q15 coefficients |
| Sample collector | `signal_generation_top` | 18-bit x 16 | Raises `fft_trigger` when the block is full |
| FFT | `fft_16pt_pipelined` | 18-bit in, 36-bit bins | 4 pipeline stages, radix-2 DIF |
| Debug | `ila_0` (Xilinx IP) | 16 probes | Live capture in Vivado Hardware Manager |

---

## How Each Block Works

### 1. DDS phase accumulators and CORDIC sine generation
Each tone has a 16-bit phase register that is increased by a fixed step on every clock. The phase is in radians with 13 fractional bits, so π = 25736. When the phase passes +π it wraps around to −π.

`phase_inc = round(2π × f / fs × 2^13)`

The design is built for a sample rate of `fs = 100 MHz` (the simulation clock is 10 ns). The Arty Z7's on-board oscillator runs at 125 MHz and drives the design directly, so on the board every frequency is 1.25 times higher. The digital results (filter gains in dB and FFT bin positions) are the same at both clock rates.

| Tone (fs = 100 MHz) | Phase increment | Tone on the board (fs = 125 MHz) |
|---------------------|-----------------|----------------------------------|
| 2 MHz | 1029 | 2.50 MHz |
| 15 MHz | 7721 | 18.75 MHz |
| 25 MHz | 12868 | 31.25 MHz |
| 30 MHz | 15442 | 37.50 MHz |

Each phase value goes into a **CORDIC IP** (sin/cos mode). The upper 16 bits of its output are the sine value.

### 2. Pipelined mixer
The four sines are added in two pipeline stages to keep timing clean:

```
stage 1:  sum1 = sine_2mhz  + sine_15mhz      sum2 = sine_25mhz + sine_30mhz     (17-bit)
stage 2:  mixed_signal = sum1 + sum2                                              (18-bit)
```
The mixer only starts when all four CORDIC outputs report valid.

### 3. 9-tap low-pass FIR filter
Symmetric 9-tap filter with Q15 coefficients (`1533, 3307, 4960, 6131, 6554, 6131, 4960, 3307, 1533`). The pipeline has six register stages: shift register, multipliers, two adder levels, accumulator, and a `>> 15` scaling step. A valid flag travels alongside the data.

Computed from the coefficients. DC gain is 1.17 and the −3 dB point is at 0.063 × fs (6.3 MHz at 100 MHz, 7.9 MHz at 125 MHz). The gains are the same at both clock rates:

| Input tone (100 MHz / 125 MHz) | Filter gain |
|--------------------------------|-------------|
| 2 MHz / 2.5 MHz | +1.1 dB (passes) |
| 15 MHz / 18.75 MHz | −24.6 dB |
| 25 MHz / 31.25 MHz | −40.8 dB |
| 30 MHz / 37.5 MHz | −30.0 dB |

So the filter output is dominated by the 2 MHz tone, as seen in the ILA capture.

### 4. Sample collector
Every valid filter output is written into a 16-entry buffer. When the 16th entry is written, `fft_trigger` pulses for one clock.

### 5. 16-point pipelined FFT
A hand-written radix-2 decimation-in-frequency FFT with four pipeline stages:

| Stage | Butterfly distance | Twiddles used |
|-------|--------------------|---------------|
| 1 | 8 | W16^0 to W16^7 |
| 2 | 4 | W16^0, 2, 4, 6 |
| 3 | 2 | W16^0, 4 |
| 4 | 1 | none (no multipliers) |

- Twiddle factors are Q15. Each stage divides by 2, so every bin equals the DFT divided by 16.
- The output is re-ordered by bit reversal. Each bin packs `{real[35:18], imag[17:0]}`.
- With 16 points, bins are **fs / 16 apart** (6.25 MHz at 100 MHz, 7.8125 MHz at 125 MHz). At either clock rate the four tones land at bin 0.32, 2.4, 4.0, and 4.8.

### 6. ILA debug core
16 probes capture the signals below, so the full chain can be viewed live in Vivado Hardware Manager.

| Probe | Signal | Width |
|-------|--------|-------|
| 0 | `rst` | 1 |
| 1 to 4 | `sine_2mhz`, `sine_15mhz`, `sine_25mhz`, `sine_30mhz` | 16 |
| 5 | `mixed_signal` | 18 |
| 6 | `filter_output` | 18 |
| 7 to 14 | `bin_0` to `bin_7` | 36 |
| 15 | `bin_8[35:18]` (real part) | 18 |

---

## Hardware Results (Arty Z7)

The ILA capture on the board shows the composite signal (four tones) and the smooth low-pass output, together with the FFT bins.

### Board connections

| Signal | Pin | Notes |
|--------|-----|-------|
| `clk` | H16 | 125 MHz on-board oscillator |
| `rst` | D19 (BTN0) | Active-high reset: press the button to reset |

No other pins are used. All internal signals are observed through the ILA.

### Post-implementation utilization and power
<img width="1592" height="410" alt="Screenshot 2026-07-10 120358" src="https://github.com/user-attachments/assets/8ba3f8e9-40ec-4f92-aace-eec6f4351ec4" />


| Resource | Utilization |
|----------|-------------|
| LUT | 63% |
| LUTRAM | 23% |
| FF | 44% |
| BRAM | 52% (includes the ILA debug logic) |
| DSP | 61% |
| IO / BUFG | 2% / 6% |

Total on-chip power **0.301 W**, junction temperature **28.5 °C**.

### Timing summary
<img width="1105" height="305" alt="Screenshot 2026-07-10 120604" src="https://github.com/user-attachments/assets/df415ea0-3532-4cc2-95b3-4577eaf3486b" />


| Check | Slack | Failing endpoints |
|-------|-------|-------------------|
| Setup (WNS) | +1.765 ns | 0 |
| Hold (WHS) | +0.016 ns | 0 |
| Pulse width (WPWS) | +6.750 ns | 0 |

All user-specified timing constraints are met. Clock constraint used for these results: **16.000 ns (62.5 MHz)**.

### Device layout and schematic views
<img width="1552" height="812" alt="Screenshot 2026-07-10 120644" src="https://github.com/user-attachments/assets/4f2e2a7d-9113-4e7a-8f1f-57e68efff9cf" />


<img width="1592" height="832" alt="Screenshot 2026-07-10 120910" src="https://github.com/user-attachments/assets/972cbe30-a6b1-4753-b99c-34d25a269bc1" />


<img width="1566" height="815" alt="Screenshot 2026-07-10 120827" src="https://github.com/user-attachments/assets/0918a708-d4d1-4859-b354-ba85d7955124" />


---

## Simulation and Verification

**FFT unit test (`tb/tb_fft_check.v`).** A self-checking testbench compares every output bin of `fft_16pt_pipelined` with an ideal DFT divided by 16, for six inputs: a tone at bin 2, DC, a tone at bin 4 with a phase offset, random data, two tones plus DC, and an impulse. The tolerance is 4 LSB.

```
---------------------------------------------------
FFT UNIT TEST (ideal DFT / 16 as reference)
---------------------------------------------------
PASS  tone at bin 2  (max error 1.3 LSB)
PASS  DC level  (max error 0.0 LSB)
PASS  tone at bin 4  (max error 1.0 LSB)
PASS  random data  (max error 1.8 LSB)
PASS  two tones + DC  (max error 1.0 LSB)
PASS  impulse  (max error 1.0 LSB)
---------------------------------------------------
FFT CHECK PASSED: all tests within 4 LSB
---------------------------------------------------
```

---

## Repository Structure

```
dsp-signal-chain-fpga/
├── rtl/
│   ├── signal_generation_top.v     # top level, mixer, collector, fir_9tap_lpf
│   └── fft_16pt_pipelined.v        # custom pipelined FFT
├── tb/
│   ├── tb_signal_generation.v      # full-chain testbench
│   └── tb_fft_check.v              # self-checking FFT unit test
├── constraints/
│   └── arty_z7.xdc                 # clock, reset, bitstream settings
├── docs/
│   ├── dsp_architecture.png
│   ├── hardware_validation.jpg
│   ├── utilization_power.png
│   ├── timing_summary.png
│   ├── device_layout.png
│   ├── schematic_485cells.png
│   ├── schematic_2332cells.png
│   └── simulation_output.png
└── README.md
```

---

## How to Run

The design uses two Xilinx IP cores that are not included as source, so create them first:

1. Create a Vivado project for the Arty Z7, add the files in `rtl/` as design sources and `constraints/arty_z7.xdc` as the constraints file
2. In the IP Catalog, generate **CORDIC** as `cordic_0`: sin/cos function, 16-bit phase input in radians, 16-bit output
3. Generate an **ILA** as `ila_0` with 16 probes, using the widths in the probe table above
4. Add the files in `tb/` as simulation sources
5. For the FFT unit test, set `tb_fft_check` as the simulation top. For the full chain, set `signal_generation_tb`
6. Run **Behavioral Simulation** (about 10 µs for the full chain)
7. For hardware: generate the bitstream, program the board, and open the ILA in Hardware Manager

---

## Tools Used

- Verilog HDL
- Xilinx Vivado (simulation, synthesis, implementation, ILA)
- Xilinx CORDIC IP and Integrated Logic Analyzer IP
- Digilent Arty Z7 development board

---

## Limitations and Future Work

- With 16 points the frequency resolution is fs / 16 (6.25 MHz at 100 MS/s), and no window function is applied, so tones that fall between bins leak into neighbouring bins.
- Timing was closed against a 16 ns constraint (62.5 MHz). The worst setup path is about 14 ns, so running at the board's full 125 MHz would need more pipelining, for example registering the FFT multiplier outputs.
- The FIR filter has only 9 taps, so its transition is gentle (the 15 MHz tone is reduced by about 25 dB, not removed).
- The FFT outputs real and imaginary parts only; adding a magnitude calculation would make the spectrum easier to read.
- The FFT pipeline is free-running (`start_i` is not used inside the module), and every stage divides by 2, which loses some precision for small signals.
- `data_out_valid` of the FIR trails `data_out` by one clock. This is harmless here because the stream is continuous.
- All signals are generated and observed inside the FPGA. Future work: output through a DAC or PS interface, window functions, and a larger FFT.

---

## Author

**Sumit**
RTL Design | Verilog | DSP | FPGA
