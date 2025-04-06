@echo off
REM Enter the correct directory first
cd /d "C:\Users\jesse\OneDrive\T3 Project\T3-Base\T3-Contract"

echo 🚀 Running Recipient-Initiated Reversal Test...
call npx hardhat run scripts\recipient_initiated_reversal.js --network sepolia
IF %ERRORLEVEL% NEQ 0 (
    echo ❌ Recipient-initiated reversal test failed.
    exit /b %ERRORLEVEL%
) ELSE (
    echo ✅ Recipient-initiated reversal test succeeded.
)

echo 🚀 Running Sender-Initiated Reversal Test...
call npx hardhat run scripts\sender_initiated_reversal.js --network sepolia
IF %ERRORLEVEL% NEQ 0 (
    echo ❌ Sender-initiated reversal test failed.
    exit /b %ERRORLEVEL%
) ELSE (
    echo ✅ Sender-initiated reversal test succeeded.
)

echo 🎉 All tests completed successfully!
pause
