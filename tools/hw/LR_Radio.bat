@echo off
rem Lightning Receiver FM radio GUI - double-click to start (no console window).
rem The GUI starts the JTAG bridge and initialises the AD9361 on demand.
start "" pythonw "%~dp0lr_radio_gui.py"
