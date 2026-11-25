; The app starts suhyeok-server detached, so it can still be running (holding its .exe) when the app is updated or
; removed. Stop it first; its open conversations reopen the next time it starts.
!macro NSIS_HOOK_PREINSTALL
  nsExec::Exec 'taskkill /F /IM suhyeok-server.exe'
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  nsExec::Exec 'taskkill /F /IM suhyeok-server.exe'
!macroend
