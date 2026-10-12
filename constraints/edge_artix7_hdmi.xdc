## vidsynth - EDGE Artix 7 (xc7a35tftg256-1), HDMI output, 50 MHz clock
##
## FILL IN THE PINS: replace every XX with the pin from the kit's master XDC.
## Vivado refuses to implement while any XX remains.
## HDMI: give only the _P pin of each TMDS pair; Vivado places the _N pin.
## Lanes: hdmi_d_p[0] = TMDS data 0 (blue), [1] = data 1 (green), [2] = data 2 (red).
## DDC: SCL is HDMI connector pin 15, SDA is pin 16. If the board does not route
## them to the FPGA, delete the two DDC lines and build with EDID_ENABLE = 0.

## ---- clock: one primary clock; Vivado derives the MMCM clocks automatically
set_property -dict { PACKAGE_PIN N11 IOSTANDARD LVCMOS18 } [get_ports clk]
create_clock -name sys_clk -period 20.000 [get_ports clk]

## ---- HDMI TMDS outputs (current-mode, termination is in the monitor)
set_property -dict { PACKAGE_PIN XX IOSTANDARD TMDS_33 } [get_ports hdmi_clk_p]
set_property -dict { PACKAGE_PIN XX IOSTANDARD TMDS_33 } [get_ports {hdmi_d_p[0]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD TMDS_33 } [get_ports {hdmi_d_p[1]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD TMDS_33 } [get_ports {hdmi_d_p[2]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_clk_n hdmi_d_n[*]}]

## ---- DDC (open drain, weak pull-ups as a fallback to the board's resistors)
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 PULLUP TRUE } [get_ports ddc_scl]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 PULLUP TRUE } [get_ports ddc_sda]

## ---- slide switches
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {sw[0]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {sw[1]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {sw[2]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {sw[3]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {sw[4]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {sw[5]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {sw[6]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {sw[7]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {sw[8]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {sw[9]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {sw[10]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {sw[11]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {sw[12]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {sw[13]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {sw[14]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {sw[15]}]

## ---- LEDs
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {led[3]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {led[4]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {led[5]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {led[6]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {led[7]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {led[8]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {led[9]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {led[10]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {led[11]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {led[12]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {led[13]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {led[14]}]
set_property -dict { PACKAGE_PIN XX IOSTANDARD LVCMOS33 } [get_ports {led[15]}]

## ---- reset button (reads 1 when pressed)
set_property -dict { PACKAGE_PIN L4  IOSTANDARD LVCMOS18 } [get_ports btn_rst]

## ---- timing exceptions: asynchronous user I/O, synchronised in logic
set_false_path -from [get_ports {sw[*] btn_rst ddc_scl ddc_sda}]
set_false_path -to   [get_ports {led[*] ddc_scl ddc_sda}]

## ---- configuration
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
