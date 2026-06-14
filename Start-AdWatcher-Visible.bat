@echo off
rem Starts the ad watcher with a visible console window (useful for testing).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SpotifyAdRestarter.ps1"
pause
