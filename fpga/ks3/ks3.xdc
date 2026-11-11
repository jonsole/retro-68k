# retro68k on the ZX Spectrum Next KS3 (issue 5): XC7A35T-2CSG324
# Pin locations from the Next's own zxnext_pins_issue5.xdc
# (https://gitlab.com/SpectrumNext/ZX_Spectrum_Next_FPGA, cores/zxnext/src).
# FT232H pins on accel_io are provisional (spec 14, open point U6).

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLUP [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# ---- pins
set_property -dict {PACKAGE_PIN T5 IOSTANDARD LVCMOS33} [get_ports clock_50_i]
set_property -dict {PACKAGE_PIN V9 IOSTANDARD LVCMOS33} [get_ports btn_reset_n_i]
set_property -dict {PACKAGE_PIN T8 IOSTANDARD LVCMOS33} [get_ports btn_multiface_n_i]
set_property -dict {PACKAGE_PIN T9 IOSTANDARD LVCMOS33} [get_ports btn_divmmc_n_i]
set_property -dict {PACKAGE_PIN U16 IOSTANDARD LVCMOS33} [get_ports audioint_o]
set_property -dict {PACKAGE_PIN B4 IOSTANDARD LVCMOS33} [get_ports audioext_l_o]
set_property -dict {PACKAGE_PIN A4 IOSTANDARD LVCMOS33} [get_ports audioext_r_o]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33} [get_ports joysel_o]
set_property -dict {PACKAGE_PIN L13 IOSTANDARD LVCMOS33} [get_ports flash_cs_n_o]
set_property -dict {PACKAGE_PIN N1 IOSTANDARD LVCMOS33} [get_ports sd_cs0_n_o]
set_property -dict {PACKAGE_PIN K2 IOSTANDARD LVCMOS33} [get_ports sd_cs1_n_o]
set_property -dict {PACKAGE_PIN M2 IOSTANDARD LVCMOS33} [get_ports sd_mosi_o]
set_property -dict {PACKAGE_PIN M1 IOSTANDARD LVCMOS33} [get_ports sd_sclk_o]
set_property -dict {PACKAGE_PIN L1 IOSTANDARD LVCMOS33 PULLUP true} [get_ports sd_miso_i]
set_property -dict {PACKAGE_PIN N5 IOSTANDARD LVCMOS33 DRIVE 16 PULLUP true} [get_ports ps2_clk_io]
set_property -dict {PACKAGE_PIN N6 IOSTANDARD LVCMOS33 DRIVE 16 PULLUP true} [get_ports ps2_data_io]
set_property -dict {PACKAGE_PIN A13 IOSTANDARD LVCMOS33} [get_ports hsync_o]
set_property -dict {PACKAGE_PIN B13 IOSTANDARD LVCMOS33} [get_ports vsync_o]
set_property -dict {PACKAGE_PIN A3 IOSTANDARD LVCMOS33} [get_ports vgaclk_o]
set_property -dict {PACKAGE_PIN C2 IOSTANDARD LVCMOS33} [get_ports vgaclkn_o]
set_property -dict {PACKAGE_PIN F4 IOSTANDARD LVCMOS33} [get_ports ram_oe_n_o]
set_property -dict {PACKAGE_PIN M4 IOSTANDARD LVCMOS33} [get_ports ram_we_n_o]
set_property -dict {PACKAGE_PIN F1 IOSTANDARD LVCMOS33} [get_ports ram_cs_n_o]
set_property -dict {PACKAGE_PIN F5 IOSTANDARD LVCMOS33} [get_ports ram_lb_n_o]
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports ram_ub_n_o]
set_property -dict {PACKAGE_PIN C1 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[0]}]
set_property -dict {PACKAGE_PIN D2 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[1]}]
set_property -dict {PACKAGE_PIN E1 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[2]}]
set_property -dict {PACKAGE_PIN F3 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[3]}]
set_property -dict {PACKAGE_PIN E2 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[4]}]
set_property -dict {PACKAGE_PIN G4 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[5]}]
set_property -dict {PACKAGE_PIN J2 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[6]}]
set_property -dict {PACKAGE_PIN N2 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[7]}]
set_property -dict {PACKAGE_PIN R5 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[8]}]
set_property -dict {PACKAGE_PIN P5 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[9]}]
set_property -dict {PACKAGE_PIN R3 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[10]}]
set_property -dict {PACKAGE_PIN P3 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[11]}]
set_property -dict {PACKAGE_PIN T3 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[12]}]
set_property -dict {PACKAGE_PIN P4 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[13]}]
set_property -dict {PACKAGE_PIN R1 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[14]}]
set_property -dict {PACKAGE_PIN T1 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[15]}]
set_property -dict {PACKAGE_PIN R2 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[16]}]
set_property -dict {PACKAGE_PIN P2 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[17]}]
set_property -dict {PACKAGE_PIN V2 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[18]}]
set_property -dict {PACKAGE_PIN R6 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[19]}]
set_property -dict {PACKAGE_PIN N4 IOSTANDARD LVCMOS33} [get_ports {ram_addr_o[20]}]
set_property -dict {PACKAGE_PIN G2 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[0]}]
set_property -dict {PACKAGE_PIN G1 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[1]}]
set_property -dict {PACKAGE_PIN H2 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[2]}]
set_property -dict {PACKAGE_PIN H1 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[3]}]
set_property -dict {PACKAGE_PIN U1 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[4]}]
set_property -dict {PACKAGE_PIN V1 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[5]}]
set_property -dict {PACKAGE_PIN U2 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[6]}]
set_property -dict {PACKAGE_PIN M3 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[7]}]
set_property -dict {PACKAGE_PIN D3 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[8]}]
set_property -dict {PACKAGE_PIN A5 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[9]}]
set_property -dict {PACKAGE_PIN D4 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[10]}]
set_property -dict {PACKAGE_PIN A6 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[11]}]
set_property -dict {PACKAGE_PIN U9 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[12]}]
set_property -dict {PACKAGE_PIN V6 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[13]}]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[14]}]
set_property -dict {PACKAGE_PIN U3 IOSTANDARD LVCMOS33} [get_ports {ram_data_io[15]}]
set_property -dict {PACKAGE_PIN K1 IOSTANDARD LVCMOS33} [get_ports {rgb_r_o[0]}]
set_property -dict {PACKAGE_PIN L4 IOSTANDARD LVCMOS33} [get_ports {rgb_r_o[1]}]
set_property -dict {PACKAGE_PIN L3 IOSTANDARD LVCMOS33} [get_ports {rgb_r_o[2]}]
set_property -dict {PACKAGE_PIN L5 IOSTANDARD LVCMOS33} [get_ports {rgb_r_o[3]}]
set_property -dict {PACKAGE_PIN K3 IOSTANDARD LVCMOS33} [get_ports {rgb_g_o[0]}]
set_property -dict {PACKAGE_PIN K5 IOSTANDARD LVCMOS33} [get_ports {rgb_g_o[1]}]
set_property -dict {PACKAGE_PIN K6 IOSTANDARD LVCMOS33} [get_ports {rgb_g_o[2]}]
set_property -dict {PACKAGE_PIN J5 IOSTANDARD LVCMOS33} [get_ports {rgb_g_o[3]}]
set_property -dict {PACKAGE_PIN J3 IOSTANDARD LVCMOS33} [get_ports {rgb_b_o[0]}]
set_property -dict {PACKAGE_PIN J4 IOSTANDARD LVCMOS33} [get_ports {rgb_b_o[1]}]
set_property -dict {PACKAGE_PIN H4 IOSTANDARD LVCMOS33} [get_ports {rgb_b_o[2]}]
set_property -dict {PACKAGE_PIN G3 IOSTANDARD LVCMOS33} [get_ports {rgb_b_o[3]}]
set_property -dict {PACKAGE_PIN E6 IOSTANDARD TMDS_33} [get_ports {hdmi_p_o[0]}]
set_property -dict {PACKAGE_PIN H14 IOSTANDARD TMDS_33} [get_ports {hdmi_p_o[1]}]
set_property -dict {PACKAGE_PIN H6 IOSTANDARD TMDS_33} [get_ports {hdmi_p_o[2]}]
set_property -dict {PACKAGE_PIN C11 IOSTANDARD TMDS_33} [get_ports {hdmi_p_o[3]}]
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33} [get_ports {accel_io[0]}]
set_property -dict {PACKAGE_PIN G16 IOSTANDARD LVCMOS33} [get_ports {accel_io[1]}]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports {accel_io[2]}]
set_property -dict {PACKAGE_PIN P17 IOSTANDARD LVCMOS33} [get_ports {accel_io[3]}]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports {accel_io[4]}]
set_property -dict {PACKAGE_PIN F14 IOSTANDARD LVCMOS33} [get_ports {accel_io[5]}]
set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33} [get_ports {accel_io[6]}]
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports {accel_io[7]}]
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {accel_io[8]}]
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports {accel_io[9]}]
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33} [get_ports {accel_io[10]}]
set_property -dict {PACKAGE_PIN J17 IOSTANDARD LVCMOS33} [get_ports {accel_io[11]}]
set_property -dict {PACKAGE_PIN F15 IOSTANDARD LVCMOS33} [get_ports {accel_io[12]}]
set_property -dict {PACKAGE_PIN E16 IOSTANDARD LVCMOS33} [get_ports {accel_io[13]}]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports {accel_io[14]}]
set_property -dict {PACKAGE_PIN M17 IOSTANDARD LVCMOS33} [get_ports {accel_io[15]}]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports {accel_io[16]}]
set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} [get_ports {accel_io[17]}]
set_property -dict {PACKAGE_PIN L18 IOSTANDARD LVCMOS33} [get_ports {accel_io[18]}]
set_property -dict {PACKAGE_PIN E15 IOSTANDARD LVCMOS33} [get_ports {accel_io[19]}]
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports {accel_io[20]}]
set_property -dict {PACKAGE_PIN B7 IOSTANDARD LVCMOS33} [get_ports {accel_io[21]}]
set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS33} [get_ports {accel_io[22]}]
set_property -dict {PACKAGE_PIN R15 IOSTANDARD LVCMOS33} [get_ports {accel_io[23]}]
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS33} [get_ports {accel_io[24]}]
set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS33} [get_ports {accel_io[25]}]
set_property -dict {PACKAGE_PIN F18 IOSTANDARD LVCMOS33} [get_ports {accel_io[26]}]
set_property -dict {PACKAGE_PIN T14 IOSTANDARD LVCMOS33} [get_ports {accel_io[27]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_n_o[*]}]

# ---- electrical settings, as on the Next
set_property -dict {DRIVE 8 SLEW FAST} [get_ports {ram_addr_o[*] ram_data_io[*] ram_oe_n_o ram_we_n_o ram_cs_n_o ram_lb_n_o ram_ub_n_o}]
set_property PULLUP true [get_ports {ram_data_io[*]}]
set_property -dict {DRIVE 8 SLEW FAST} [get_ports {rgb_r_o[*] rgb_g_o[*] rgb_b_o[*] vgaclk_o vgaclkn_o}]
set_property DRIVE 8 [get_ports {hsync_o vsync_o}]
set_property PULLUP true [get_ports {btn_reset_n_i btn_multiface_n_i btn_divmmc_n_i}]
set_property DRIVE 4 [get_ports {accel_io[*]}]
set_property PULLUP true [get_ports {accel_io[*]}]      ;# RXF# and TXE# read 'not ready' with no module

# ---- clocks
create_clock -name clk50 -period 20.000 [get_ports clock_50_i]

# The pixel clocks (MMCM 2, 576p) and the system clocks (MMCM 1) come from
# the same oscillator but have no designed phase relation: every signal
# between them goes through a synchroniser or a handshake, or is a setting
# that only changes between lines (spec 4, section 3.1)
set_clock_groups -asynchronous \
    -group [get_clocks -of_objects [get_pins clocks/mmcm_sys/CLKOUT*]] \
    -group [get_clocks -of_objects [get_pins clocks/mmcm_pix/CLKOUT*]]
# Layer CTRL.TRANSP and PALOFS are read raw, every pixel, by the layer pixel
# units (spec 4, section 5.4; retro-hw layer_pix spec 4.4): while they
# change, one pixel may show a mix of the old and new bits. The clock
# groups above cover the path already; this names it as deliberate.
set_false_path -from [get_cells -hier -filter {NAME =~ sys/vid/l_ctrl_reg* && IS_SEQUENTIAL}] \
    -to [get_clocks -of_objects [get_pins clocks/mmcm_pix/CLKOUT*]]
set clk100 [get_clocks -of_objects [get_pins clocks/mmcm_sys/CLKOUT0]]
set clk40  [get_clocks -of_objects [get_pins clocks/mmcm_sys/CLKOUT1]]

# 40 MHz <-> 100 MHz: signals change only at fixed points of the 50 ns grid and
# are captured at least 15 ns later (spec 1, section 3), not the default 5 ns.
set_max_delay 15.000 -from $clk40 -to $clk100
set_max_delay 15.000 -from $clk100 -to $clk40
# ...except the reset's grid finder, which relies on the 5 ns path (por_align.v)
set_max_delay 4.000 -from [get_cells pa/t40_reg] -to [get_cells {pa/smp_reg[0]}]

# fx68k: the microcode address isn't needed in the next cycle (fx68k.txt)
set_multicycle_path -setup 2 -from [get_pins -hier -filter {NAME =~ sys/cpu/core/Ir_reg*/C}] -to [get_pins -hier -filter {NAME =~ sys/cpu/core/microAddr_reg*/D || NAME =~ sys/cpu/core/nanoAddr_reg*/D}]
set_multicycle_path -hold 1 -from [get_pins -hier -filter {NAME =~ sys/cpu/core/Ir_reg*/C}] -to [get_pins -hier -filter {NAME =~ sys/cpu/core/microAddr_reg*/D || NAME =~ sys/cpu/core/nanoAddr_reg*/D}]

# Buttons and the FT232H's RXF#/TXE# are asynchronous (synchronised inside)
set_false_path -from [get_ports {btn_reset_n_i btn_multiface_n_i btn_divmmc_n_i}]
set_false_path -from [get_ports {accel_io[*]}]
set_false_path -to   [get_ports {accel_io[*]}]
# PS/2 is asynchronous (filtered inside); the SD card's SPI timing is set by the
# design (MISO is taken half an SPI clock after the card changes it)
set_false_path -from [get_ports {ps2_clk_io ps2_data_io sd_miso_i}]
set_false_path -to   [get_ports {ps2_clk_io ps2_data_io sd_sclk_o sd_mosi_o sd_cs0_n_o sd_cs1_n_o}]

# SRAM read data: captured in the input pad flip-flops (spec 5, section 4.2)
set_property IOB TRUE [get_cells -hier -filter {NAME =~ sys/mem/rdata_reg*}]
