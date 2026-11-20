## vidsynth - EDGE Artix 7 (xc7a35tftg256-1), HDMI output, 50 MHz clock
## Pins from the EDGE master XDC rev 2.1 (schematic ARTIX7_V3). All user I/O is LVCMOS33.
## Lanes: hdmi_d_p[0] = TMDS data 0 (blue), [1] = data 1 (green), [2] = data 2 (red).
## The board does not route DDC (SCL/SDA) or HPD to the FPGA: build with noedid
## (set argv {edge noedid}). The two DDC ports are parked on unused J11 header pins
## so the bitstream DRC passes; they stay tri-stated. Leave J11 unconnected.

## ---- clock
set_property -dict { PACKAGE_PIN N11 IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -name sys_clk -period 20.000 [get_ports clk]

## ---- HDMI TMDS outputs (give only the _P pin; Vivado places _N)
set_property -dict { PACKAGE_PIN E3 IOSTANDARD TMDS_33 } [get_ports hdmi_clk_p]
set_property -dict { PACKAGE_PIN A5 IOSTANDARD TMDS_33 } [get_ports {hdmi_d_p[0]}]
set_property -dict { PACKAGE_PIN B6 IOSTANDARD TMDS_33 } [get_ports {hdmi_d_p[1]}]
set_property -dict { PACKAGE_PIN B7 IOSTANDARD TMDS_33 } [get_ports {hdmi_d_p[2]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_clk_n hdmi_d_n[*]}]

## ---- DDC: not wired on this board (parked on J11 pins, tri-stated with EDID_ENABLE = 0)
set_property -dict { PACKAGE_PIN M16 IOSTANDARD LVCMOS33 PULLUP TRUE } [get_ports ddc_scl]
set_property -dict { PACKAGE_PIN N16 IOSTANDARD LVCMOS33 PULLUP TRUE } [get_ports ddc_sda]

## ---- slide switches (sw[0] = rightmost)
set_property -dict { PACKAGE_PIN L5  IOSTANDARD LVCMOS33 } [get_ports {sw[0]}]
set_property -dict { PACKAGE_PIN L4  IOSTANDARD LVCMOS33 } [get_ports {sw[1]}]
set_property -dict { PACKAGE_PIN M4  IOSTANDARD LVCMOS33 } [get_ports {sw[2]}]
set_property -dict { PACKAGE_PIN M2  IOSTANDARD LVCMOS33 } [get_ports {sw[3]}]
set_property -dict { PACKAGE_PIN M1  IOSTANDARD LVCMOS33 } [get_ports {sw[4]}]
set_property -dict { PACKAGE_PIN N3  IOSTANDARD LVCMOS33 } [get_ports {sw[5]}]
set_property -dict { PACKAGE_PIN N2  IOSTANDARD LVCMOS33 } [get_ports {sw[6]}]
set_property -dict { PACKAGE_PIN N1  IOSTANDARD LVCMOS33 } [get_ports {sw[7]}]
set_property -dict { PACKAGE_PIN P1  IOSTANDARD LVCMOS33 } [get_ports {sw[8]}]
set_property -dict { PACKAGE_PIN P4  IOSTANDARD LVCMOS33 } [get_ports {sw[9]}]
set_property -dict { PACKAGE_PIN T8  IOSTANDARD LVCMOS33 } [get_ports {sw[10]}]
set_property -dict { PACKAGE_PIN R8  IOSTANDARD LVCMOS33 } [get_ports {sw[11]}]
set_property -dict { PACKAGE_PIN N6  IOSTANDARD LVCMOS33 } [get_ports {sw[12]}]
set_property -dict { PACKAGE_PIN T7  IOSTANDARD LVCMOS33 } [get_ports {sw[13]}]
set_property -dict { PACKAGE_PIN P8  IOSTANDARD LVCMOS33 } [get_ports {sw[14]}]
set_property -dict { PACKAGE_PIN M6  IOSTANDARD LVCMOS33 } [get_ports {sw[15]}]

## ---- LEDs
set_property -dict { PACKAGE_PIN J3  IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN H3  IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN J1  IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN K1  IOSTANDARD LVCMOS33 } [get_ports {led[3]}]
set_property -dict { PACKAGE_PIN L3  IOSTANDARD LVCMOS33 } [get_ports {led[4]}]
set_property -dict { PACKAGE_PIN L2  IOSTANDARD LVCMOS33 } [get_ports {led[5]}]
set_property -dict { PACKAGE_PIN K3  IOSTANDARD LVCMOS33 } [get_ports {led[6]}]
set_property -dict { PACKAGE_PIN K2  IOSTANDARD LVCMOS33 } [get_ports {led[7]}]
set_property -dict { PACKAGE_PIN K5  IOSTANDARD LVCMOS33 } [get_ports {led[8]}]
set_property -dict { PACKAGE_PIN P6  IOSTANDARD LVCMOS33 } [get_ports {led[9]}]
set_property -dict { PACKAGE_PIN R7  IOSTANDARD LVCMOS33 } [get_ports {led[10]}]
set_property -dict { PACKAGE_PIN R6  IOSTANDARD LVCMOS33 } [get_ports {led[11]}]
set_property -dict { PACKAGE_PIN T5  IOSTANDARD LVCMOS33 } [get_ports {led[12]}]
set_property -dict { PACKAGE_PIN R5  IOSTANDARD LVCMOS33 } [get_ports {led[13]}]
set_property -dict { PACKAGE_PIN T10 IOSTANDARD LVCMOS33 } [get_ports {led[14]}]
set_property -dict { PACKAGE_PIN T9  IOSTANDARD LVCMOS33 } [get_ports {led[15]}]

## ---- reset button: centre push button SW22 (reads 1 when pressed, 10k pull-down on board)
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports btn_rst]

## ---- timing exceptions: asynchronous user I/O, synchronised in logic
set_false_path -from [get_ports {sw[*] btn_rst ddc_scl ddc_sda}]
set_false_path -to   [get_ports {led[*] ddc_scl ddc_sda}]

## ---- configuration
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
