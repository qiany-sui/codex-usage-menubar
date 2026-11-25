!define WATCHER_RUN_KEY "Software\Microsoft\Windows\CurrentVersion\Run"
!define WATCHER_RUN_NAME "Codex Usage Watcher"

!macro StopCodexUsageCompanion
  ; 老版本还没有助手或退出协议，只交给 Tauri 的现有检查处理。
  ReadRegStr $0 HKCU "${WATCHER_RUN_KEY}" "${WATCHER_RUN_NAME}"
  ${If} $0 == '$\"$INSTDIR\${MAINBINARYNAME}.exe$\" --watch-codex'
  ${AndIf} ${FileExists} "$INSTDIR\${MAINBINARYNAME}.exe"
    ClearErrors
    ExecWait '$\"$INSTDIR\${MAINBINARYNAME}.exe$\" --stop-companion' $1
    ${If} ${Errors}
      Abort "Could not request Codex Usage to stop. Please quit it and retry."
    ${EndIf}
    ${If} $1 != 0
      Abort "Could not stop Codex Usage. Please quit it and retry."
    ${EndIf}
  ${EndIf}
!macroend

!macro NSIS_HOOK_PREINSTALL
  !insertmacro StopCodexUsageCompanion
!macroend

!macro NSIS_HOOK_POSTINSTALL
  WriteRegStr HKCU "${WATCHER_RUN_KEY}" "${WATCHER_RUN_NAME}" '$\"$INSTDIR\${MAINBINARYNAME}.exe$\" --watch-codex'
  nsis_tauri_utils::RunAsUser "$INSTDIR\${MAINBINARYNAME}.exe" "--watch-codex"
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  !insertmacro StopCodexUsageCompanion
  ReadRegStr $0 HKCU "${WATCHER_RUN_KEY}" "${WATCHER_RUN_NAME}"
  ${If} $0 == '$\"$INSTDIR\${MAINBINARYNAME}.exe$\" --watch-codex'
    DeleteRegValue HKCU "${WATCHER_RUN_KEY}" "${WATCHER_RUN_NAME}"
  ${EndIf}
!macroend
