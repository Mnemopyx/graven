@echo off
rem Starts Graven and writes what it prints to graven-log.txt beside it.
"%~dp0graven-gui.exe" %* 2> "%~dp0graven-log.txt"
