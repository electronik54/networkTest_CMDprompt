@echo off
title Network Monitor
powershell -NoExit -ExecutionPolicy Bypass -File "%~dp0network_monitor.ps1"
