@echo off
setlocal EnableExtensions EnableDelayedExpansion

title AI Model Globalizer

REM Core destination root for deduplicated models.
set "GLOBAL=_global_models"
set "ROOT=%CD%"
set "GLOBAL_PATH=%ROOT%\%GLOBAL%"
set "GLOBAL_PATH_NORM=%GLOBAL_PATH%"
set "LEGACY_GLOBAL_PATH=%ROOT%\%GLOBAL%"
set "LEGACY_GLOBAL_PATH_NORM=%LEGACY_GLOBAL_PATH%"
set "LINK_MODE=AUTO"
set "RUN_MODE=normal"
set "EXPECT_GLOBAL_VALUE=0"
set "EXPECT_MODE_VALUE=0"

call :ParseArgs %*
if errorlevel 1 exit /b 1

call :NormalizePathNoTrailingSlash "%GLOBAL_PATH%" GLOBAL_PATH_NORM
if not defined GLOBAL_PATH_NORM set "GLOBAL_PATH_NORM=%GLOBAL_PATH%"
call :NormalizePathNoTrailingSlash "%LEGACY_GLOBAL_PATH%" LEGACY_GLOBAL_PATH_NORM
if not defined LEGACY_GLOBAL_PATH_NORM set "LEGACY_GLOBAL_PATH_NORM=%LEGACY_GLOBAL_PATH%"

REM File types treated as model artifacts by the scan.
set "MODEL_EXTENSIONS=*.safetensors *.gguf *.ckpt *.onnx"
set "IGNORE_DIRS=venv .venv site-packages node_modules __pycache__ cache caches tmp temp .git logs output outputs samples test tests example examples"
set "SCAN_HEARTBEAT=25"
set "FOUND_HEARTBEAT=25"

REM Temporary scan outputs used to group duplicates before execution.
set "LIST=%TEMP%\ai_model_globalizer_list.tsv"
set "GROUPS=%TEMP%\ai_model_globalizer_groups.tsv"
set "FOUND_LOG=%ROOT%\ai_model_globalizer_found_files.txt"
set "VERIFY_LOG=%ROOT%\ai_model_globalizer_verify_failures.txt"

del "%LIST%" 2>nul
del "%GROUPS%" 2>nul
del "%FOUND_LOG%" 2>nul
del "%VERIFY_LOG%" 2>nul

for /f %%T in ('powershell -NoProfile -Command "[DateTimeOffset]::Now.ToUnixTimeSeconds()"') do set "START_TS=%%T"

cls
echo ==================================================
echo              AI MODEL GLOBALIZER
echo ==================================================
echo.
echo Root folder   : %ROOT%
echo Global folder : !GLOBAL_PATH_NORM!
echo Link mode     : !LINK_MODE!
echo.

if /i "!RUN_MODE!"=="help" goto :Usage

call :MaybeMigrateLegacyGlobalStore

if /i "!RUN_MODE!"=="repair" goto :RepairOnlyMode
if /i "!RUN_MODE!"=="verify" goto :VerifyOnlyMode

echo Scanning first. Nothing will be changed yet. This might take a while.
call :RandomScanMessage
echo.

set /a TOTAL=0
set /a SKIPPED_GLOBAL=0
set /a SKIPPED_ALREADY=0
set /a SKIPPED_IGNORED=0
set /a SKIPPED_REPARSE=0
set /a SCANNED_MATCHES=0
set /a SPIN=0

REM Build a list of junction/symlink directories once so scan can skip linked trees.
echo Discovering symlink/junction paths...
call :BuildReparseList
echo Reparse dirs found: !REPARSE_COUNT!
echo.

REM Scan only model-like files, then exclude linked/globalized/ignored candidates.
echo Scanning model files...
for /r %%F in (%MODEL_EXTENSIONS%) do (
    set /a SCANNED_MATCHES+=1
    set /a SMOD=SCANNED_MATCHES %% SCAN_HEARTBEAT
    if !SMOD!==0 call :Spinner "Scanning... !SCANNED_MATCHES! model files checked, !TOTAL! queued"

    set "SRC=%%~fF"
    set "MODEL_NAME=%%~nF"
    set "FILE_NAME=%%~nxF"
    set "SIZE=%%~zF"

    call :IsInReparsePath "!SRC!"

    if "!IN_REPARSE_PATH!"=="1" (
        set /a SKIPPED_REPARSE+=1
    ) else (

        call :IsIgnoredFolder "!SRC!"

        if "!IS_IGNORED!"=="1" (
            set /a SKIPPED_IGNORED+=1
        ) else (
            call :IsUnderGlobalPath "!SRC!"
            if "!UNDER_GLOBAL_PATH!"=="1" (
            set /a SKIPPED_GLOBAL+=1
            ) else (
                call :IsAlreadyGlobalized "!SRC!"

                if "!ALREADY_GLOBALIZED!"=="1" (
                    set /a SKIPPED_ALREADY+=1
                ) else (
                    call :DetectCategory "!SRC!"
                    if not defined CATEGORY set "CATEGORY=Other"

                    set /a TOTAL+=1

                    REM Persist scan results for duplicate grouping and later execution.
                    >>"%LIST%" echo(!CATEGORY!	!MODEL_NAME!	!FILE_NAME!	!SIZE!	!SRC!
                    >>"%GROUPS%" echo(!CATEGORY!	!MODEL_NAME!	!FILE_NAME!	!SIZE!
                    >>"%FOUND_LOG%" echo(!CATEGORY!	!SRC!

                    set /a MOD=TOTAL %% FOUND_HEARTBEAT
                    if !MOD!==0 call :Spinner "Scanning... !TOTAL! model files found"
                )
            )
        )
    )
)

echo.
echo Scan complete.
call :SpinnerFlush

echo.

if !TOTAL!==0 (
    echo No new model files found.
    echo Tip: Run "%~nx0 migrate" to do repair/cleanup only.
    echo Skipped already globalized : !SKIPPED_ALREADY!
    echo Skipped global folder      : !SKIPPED_GLOBAL!
    echo Skipped ignored paths      : !SKIPPED_IGNORED!
    echo Skipped reparse paths      : !SKIPPED_REPARSE!
    echo Model files checked        : !SCANNED_MATCHES!
    echo Reparse dirs detected      : !REPARSE_COUNT!
    echo.
    pause
    exit /b
)

REM Group by category+model+file+size so only likely duplicates need hashing later.
sort "%GROUPS%" /o "%GROUPS%"

set /a UNIQUE_GROUPS=0
set /a DUPLICATE_CANDIDATES=0
set /a HASH_NEEDED=0
set "LAST="
set /a GROUP_COUNT=0

for /f "usebackq tokens=*" %%L in ("%GROUPS%") do (
    if /i "%%L"=="!LAST!" (
        set /a GROUP_COUNT+=1
    ) else (
        if defined LAST (
            set /a UNIQUE_GROUPS+=1
            if !GROUP_COUNT! gtr 1 (
                set /a DUPLICATE_CANDIDATES+=GROUP_COUNT
                set /a HASH_NEEDED+=GROUP_COUNT
            )
        )
        set "LAST=%%L"
        set /a GROUP_COUNT=1
    )
)

if defined LAST (
    set /a UNIQUE_GROUPS+=1
    if !GROUP_COUNT! gtr 1 (
        set /a DUPLICATE_CANDIDATES+=GROUP_COUNT
        set /a HASH_NEEDED+=GROUP_COUNT
    )
)

for /f %%T in ('powershell -NoProfile -Command "[DateTimeOffset]::Now.ToUnixTimeSeconds()"') do set "SCAN_END_TS=%%T"
set /a SCAN_SECONDS=SCAN_END_TS-START_TS
call :FormatSeconds !SCAN_SECONDS! SCAN_TIME

cls
echo ==================================================
echo                  SCAN RESULT
echo ==================================================
echo.
echo Model files to process    : !TOTAL!
echo Unique category/model/file/size : !UNIQUE_GROUPS!
echo Duplicate candidates      : !DUPLICATE_CANDIDATES!
echo Files needing hash        : !HASH_NEEDED!
echo Already globalized        : !SKIPPED_ALREADY!
echo Skipped global folder     : !SKIPPED_GLOBAL!
echo Skipped ignored paths     : !SKIPPED_IGNORED!
echo Skipped reparse paths     : !SKIPPED_REPARSE!
echo Model files checked       : !SCANNED_MATCHES!
echo Reparse dirs detected     : !REPARSE_COUNT!
echo Scan time                 : !SCAN_TIME!
echo.
echo Global structure:
echo !GLOBAL_PATH_NORM!\[category]\[model-name]\[size-or-hash]\[filename.ext]
echo.
echo Found-file list:
echo !FOUND_LOG!
echo.
echo E = Execute linking
echo Q = Quit without changing anything
echo.

set "ACTION="
set /p "ACTION=Selection, then press ENTER: "

REM Execution is explicit: linking only happens after confirmation.
if /i not "!ACTION!"=="E" (
    echo.
    echo Cancelled. No files were modified.
    echo.
    pause
    exit /b
)

if not exist "!GLOBAL_PATH_NORM!" mkdir "!GLOBAL_PATH_NORM!"

if !HASH_NEEDED! gtr 0 (
    call :RandomHashMessage
    echo Hashing duplicate candidates only...
    echo This can be slow. Very slow. Suspiciously slow.
    echo.
)

echo Running linking...

call :RandomExecuteMessage

set /a PROCESSED=0
set /a LINKED=0
set /a ERRORS=0
set /a MOVED=0
set /a REUSED=0
set /a HARDLINKED=0
set /a SYMLINKED=0
set /a RESTORED=0

for /f "usebackq tokens=1,2,3,4,* delims=	" %%A in ("%LIST%") do (
    set "CATEGORY=%%A"
    set "MODEL_NAME=%%B"
    set "FILE_NAME=%%C"
    set "SIZE=%%D"
    set "SRC=%%E"
    set "COUNT=0"
    set "MOVE_OK=1"
    set "MOVE_REQUIRED=0"

    for /f "usebackq tokens=1,2,3,4,* delims=	" %%W in ("%LIST%") do (
        if /i "%%W	%%X	%%Y	%%Z"=="!CATEGORY!	!MODEL_NAME!	!FILE_NAME!	!SIZE!" set /a COUNT+=1
    )

    set "ID=size_!SIZE!"

    REM Only hash when category/model/file/size is not unique.
    if !COUNT! gtr 1 (
        call :Spinner "Hashing... !FILE_NAME!"
        call :ComputeSha256 "%%E"
        if defined HASH_RESULT (
            set "ID=!HASH_RESULT!"
        ) else (
            echo.
            echo ERROR: Hash failed, using size-ID fallback: !SRC!
            set /a ERRORS+=1
        )
    )

    set "DST=!GLOBAL_PATH_NORM!\!CATEGORY!\!MODEL_NAME!\!ID!\!FILE_NAME!"

    REM Move once into the global store, then recreate source path as a link.
    set /a PROCESSED+=1
    call :Spinner "Linking... !PROCESSED! / !TOTAL!"

    for %%D in ("!DST!") do if not exist "%%~dpD" mkdir "%%~dpD"

    if exist "!DST!" (
        set /a REUSED+=1
    ) else (
        move /y "!SRC!" "!DST!" >nul
        if errorlevel 1 (
            echo.
            echo ERROR: Move to global store failed: !SRC!
            set /a ERRORS+=1
            set "MOVE_OK=0"
        ) else (
            set /a MOVED+=1
            set "MOVE_REQUIRED=1"
        )
    )

    if "!MOVE_OK!"=="1" (
        if not exist "!DST!" (
            echo.
            echo ERROR: Target missing after move/reuse: !DST!
            set /a ERRORS+=1
            if "!MOVE_REQUIRED!"=="1" (
                move /y "!DST!" "!SRC!" >nul
                if not errorlevel 1 set /a RESTORED+=1
            )
        ) else (
            set "PREP_OK=1"
            if "!MOVE_REQUIRED!"=="0" (
                del "!SRC!" >nul
                if errorlevel 1 (
                    echo.
                    echo ERROR: Could not remove source before linking: !SRC!
                    set /a ERRORS+=1
                    set "PREP_OK=0"
                )
            )

            if "!PREP_OK!"=="1" (
                set "EFFECTIVE_LINK_MODE=!LINK_MODE!"
                if /i "!EFFECTIVE_LINK_MODE!"=="AUTO" (
                    call :DetermineAutoLinkMode "!SRC!" "!DST!"
                    set "EFFECTIVE_LINK_MODE=!AUTO_LINK_MODE!"
                )

                call :CreateFileLink "!SRC!" "!DST!" "!EFFECTIVE_LINK_MODE!"
                if "!LINK_CREATE_OK!"=="1" (
                    set /a LINKED+=1
                    if /i "!EFFECTIVE_LINK_MODE!"=="HARDLINK" set /a HARDLINKED+=1
                    if /i "!EFFECTIVE_LINK_MODE!"=="SYMLINK" set /a SYMLINKED+=1
                ) else (
                    echo.
                    echo ERROR: !LINK_ERROR! :: !SRC!
                    if "!MOVE_REQUIRED!"=="1" (
                        echo ERROR: Restoring original source path...
                        move /y "!DST!" "!SRC!" >nul
                        if errorlevel 1 (
                            echo ERROR: Restore failed: !SRC!
                        ) else (
                            set /a RESTORED+=1
                        )
                    ) else (
                        echo ERROR: Restoring original source path...
                        copy /b "!DST!" "!SRC!" >nul
                        if errorlevel 1 (
                            echo ERROR: Restore failed: !SRC!
                        ) else (
                            set /a RESTORED+=1
                        )
                    )
                    set /a ERRORS+=1
                )
            )
        )
    )
)

for /f %%T in ('powershell -NoProfile -Command "[DateTimeOffset]::Now.ToUnixTimeSeconds()"') do set "END_TS=%%T"
set /a TOTAL_SECONDS=END_TS-START_TS
call :FormatSeconds !TOTAL_SECONDS! TOTAL_TIME

echo.
echo.
echo ==================================================
echo Finished
echo ==================================================
echo Processed             : !PROCESSED!
echo Moved to global       : !MOVED!
echo Reused                : !REUSED!
echo Linked                : !LINKED!
echo Hardlinks             : !HARDLINKED!
echo Symlinks              : !SYMLINKED!
echo Restored originals    : !RESTORED!
echo Errors                : !ERRORS!
echo Already globalized    : !SKIPPED_ALREADY!
echo Total time elapsed    : !TOTAL_TIME!
echo.
echo Your SSD can breathe again.
echo.
pause
exit /b


:RepairOnlyMode
echo Repair-only mode: running cleanup/migration without scan or linking.
echo.

if not exist "!GLOBAL_PATH_NORM!" mkdir "!GLOBAL_PATH_NORM!"

call :MigrateMalformedGlobalIds

for /f %%T in ('powershell -NoProfile -Command "[DateTimeOffset]::Now.ToUnixTimeSeconds()"') do set "END_TS=%%T"
set /a TOTAL_SECONDS=END_TS-START_TS
call :FormatSeconds !TOTAL_SECONDS! TOTAL_TIME

echo Repair-only run finished in !TOTAL_TIME!
echo.
pause
exit /b


:VerifyOnlyMode
echo Verify-only mode: checking whether model files are linked into the global store.
echo.

set /a VERIFY_SCANNED=0
set /a VERIFY_LINKED=0
set /a VERIFY_MISSING=0
set /a VERIFY_SKIPPED_GLOBAL=0
set /a VERIFY_SKIPPED_IGNORED=0
set /a VERIFY_SKIPPED_REPARSE=0
set /a VERIFY_HEARTBEAT=25
set /a SPIN=0

echo Discovering symlink/junction paths...
call :BuildReparseList
echo Reparse dirs found: !REPARSE_COUNT!
echo.

echo Verifying model files...
for /r %%F in (%MODEL_EXTENSIONS%) do (
    set "SRC=%%~fF"

    call :IsInReparsePath "!SRC!"

    if "!IN_REPARSE_PATH!"=="1" (
        set /a VERIFY_SKIPPED_REPARSE+=1
    ) else (
        call :IsIgnoredFolder "!SRC!"

        if "!IS_IGNORED!"=="1" (
            set /a VERIFY_SKIPPED_IGNORED+=1
        ) else (
            call :IsUnderGlobalPath "!SRC!"
            if "!UNDER_GLOBAL_PATH!"=="1" (
            set /a VERIFY_SKIPPED_GLOBAL+=1
            ) else (
                set /a VERIFY_SCANNED+=1
                set /a VMOD=VERIFY_SCANNED %% VERIFY_HEARTBEAT
                if !VMOD!==0 call :Spinner "Verify... !VERIFY_SCANNED! checked, !VERIFY_LINKED! linked, !VERIFY_MISSING! missing"

                call :IsAlreadyGlobalized "!SRC!"
                if "!ALREADY_GLOBALIZED!"=="1" (
                    set /a VERIFY_LINKED+=1
                ) else (
                    set /a VERIFY_MISSING+=1
                    >>"%VERIFY_LOG%" echo(!SRC!
                )
            )
        )
    )
)

call :SpinnerFlush
for /f %%T in ('powershell -NoProfile -Command "[DateTimeOffset]::Now.ToUnixTimeSeconds()"') do set "END_TS=%%T"
set /a TOTAL_SECONDS=END_TS-START_TS
call :FormatSeconds !TOTAL_SECONDS! TOTAL_TIME

echo.
echo Verify checked         : !VERIFY_SCANNED!
echo Verify linked          : !VERIFY_LINKED!
echo Verify missing         : !VERIFY_MISSING!
echo Verify skipped global  : !VERIFY_SKIPPED_GLOBAL!
echo Verify skipped ignored : !VERIFY_SKIPPED_IGNORED!
echo Verify skipped reparse : !VERIFY_SKIPPED_REPARSE!
echo Verify time            : !TOTAL_TIME!
if !VERIFY_MISSING! gtr 0 (
    echo Verify failure log     : !VERIFY_LOG!
) else (
    echo Verify failure log     : none
)
echo.
pause
exit /b


:BuildReparseList
REM Cache reparse-point directories so the main scan can avoid linked trees.
set /a REPARSE_COUNT=0

for /f "delims=" %%R in ('dir "%ROOT%" /s /b /ad /a:l 2^>nul') do (
    set "RPATH=%%~fR"
    set /a REPARSE_COUNT+=1
    set "REPARSE_!REPARSE_COUNT!=!RPATH!"
)

exit /b


:IsInReparsePath
REM Marks a file as skippable when it lives under a junction/symlink directory.
set "IN_REPARSE_PATH=0"
set "CHECK_FILE=%~1"

if !REPARSE_COUNT! leq 0 exit /b

for /l %%N in (1,1,!REPARSE_COUNT!) do (
    call set "RDIR=%%REPARSE_%%N%%"
    if /i "!CHECK_FILE!"=="!RDIR!" (
        set "IN_REPARSE_PATH=1"
        exit /b
    )
    if /i not "!CHECK_FILE:!RDIR!\=!"=="!CHECK_FILE!" (
        set "IN_REPARSE_PATH=1"
        exit /b
    )
)

exit /b


:IsIgnoredFolder
REM Simple substring-based ignore check for noisy development/cache folders.
set "IS_IGNORED=0"
set "CHECK_PATH=%~1"

for %%I in (%IGNORE_DIRS%) do (
    if /i not "!CHECK_PATH:\%%I\=!"=="!CHECK_PATH!" (
        set "IS_IGNORED=1"
        exit /b
    )
)

exit /b


:IsAlreadyGlobalized
REM Detect files already linked (hardlink/symlink) to a path inside global store.
set "ALREADY_GLOBALIZED=0"
set "LINK_SOURCE=%~1"

for /f "delims=" %%L in ('fsutil hardlink list "!LINK_SOURCE!" 2^>nul') do (
    set "HL=%%L"
    call :IsUnderGlobalPath "!HL!"
    if "!UNDER_GLOBAL_PATH!"=="1" (
        set "ALREADY_GLOBALIZED=1"
    )
)

if "!ALREADY_GLOBALIZED!"=="1" exit /b

set "SYMLINK_TARGET_MATCH=0"
set "SYMLINK_CHECK_PATH=!LINK_SOURCE!"
for /f %%S in ('powershell -NoProfile -Command "$src=$env:SYMLINK_CHECK_PATH; $g=$env:GLOBAL_PATH_NORM; try { $i=Get-Item -LiteralPath $src -Force -ErrorAction Stop; if($i.Attributes -band [IO.FileAttributes]::ReparsePoint){ foreach($t in @($i.Target)){ if(-not $t){ continue } if([IO.Path]::IsPathRooted($t)){ $full=[IO.Path]::GetFullPath($t) } else { $full=[IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $src) $t)) } if($full.ToLower() -eq $g.ToLower() -or $full.ToLower().StartsWith(($g + '\\').ToLower())){ Write-Output 1; break } } } } catch { }"') do set "SYMLINK_TARGET_MATCH=%%S"

if "!SYMLINK_TARGET_MATCH!"=="1" set "ALREADY_GLOBALIZED=1"

exit /b


:IsUnderGlobalPath
set "UNDER_GLOBAL_PATH=0"
set "CHECK_PATH=%~1"

if not defined CHECK_PATH exit /b
if not defined GLOBAL_PATH_NORM exit /b

if /i "!CHECK_PATH!"=="!GLOBAL_PATH_NORM!" (
    set "UNDER_GLOBAL_PATH=1"
    exit /b
)

if /i not "!CHECK_PATH:!GLOBAL_PATH_NORM!\=!"=="!CHECK_PATH!" (
    set "UNDER_GLOBAL_PATH=1"
)

exit /b


:DetermineAutoLinkMode
set "AUTO_LINK_MODE=SYMLINK"
set "ALSRC=%~1"
set "ALDST=%~2"

call :CanUseHardlink "!ALSRC!" "!ALDST!"
if "!CAN_HARDLINK!"=="1" set "AUTO_LINK_MODE=HARDLINK"

exit /b


:CanUseHardlink
set "CAN_HARDLINK=0"
set "CH_SRC=%~1"
set "CH_DST=%~2"

for %%S in ("!CH_SRC!") do set "CH_SRC_DRIVE=%%~dS"
for %%D in ("!CH_DST!") do set "CH_DST_DRIVE=%%~dD"

if /i not "!CH_SRC_DRIVE!"=="!CH_DST_DRIVE!" exit /b

call :GetFsTypeForDrive "!CH_SRC_DRIVE!" CH_SRC_FS
if /i "!CH_SRC_FS!"=="NTFS" (
    set "CAN_HARDLINK=1"
)

exit /b


:CreateFileLink
set "LINK_CREATE_OK=0"
set "LINK_ERROR="
set "CLSRC=%~1"
set "CLDST=%~2"
set "CLMODE=%~3"

if /i "!CLMODE!"=="HARDLINK" (
    call :CanUseHardlink "!CLSRC!" "!CLDST!"
    if "!CAN_HARDLINK!"=="0" (
        set "LINK_ERROR=Hardlink not supported for this source/destination (needs same NTFS volume)"
        exit /b
    )

    mklink /H "!CLSRC!" "!CLDST!" >nul
    if errorlevel 1 (
        set "LINK_ERROR=Hardlink creation failed"
        exit /b
    )

    set "LINK_CREATE_OK=1"
    exit /b
)

if /i "!CLMODE!"=="SYMLINK" (
    mklink "!CLSRC!" "!CLDST!" >nul
    if errorlevel 1 (
        set "LINK_ERROR=Symlink creation failed (admin/dev-mode permissions or policy may block it)"
        exit /b
    )

    set "LINK_CREATE_OK=1"
    exit /b
)

set "LINK_ERROR=Unsupported link mode: !CLMODE!"
exit /b


:GetFsTypeForDrive
set "%~2=UNKNOWN"
set "FS_DRIVE=%~1"
if not defined FS_DRIVE exit /b

set "FS_KEY=!FS_DRIVE::=_!"
set "FS_VAR=FS_TYPE_!FS_KEY!"
call set "FS_CACHED=%%%FS_VAR%%%"
if defined FS_CACHED (
    set "%~2=!FS_CACHED!"
    exit /b
)

set "FS_VALUE=UNKNOWN"
for /f "tokens=2,* delims=:" %%F in ('fsutil fsinfo volumeinfo !FS_DRIVE! 2^>nul ^| findstr /i "File System Name"') do (
    set "FS_VALUE=%%G"
)

if defined FS_VALUE (
    for /f "tokens=* delims= " %%X in ("!FS_VALUE!") do set "FS_VALUE=%%X"
)

if not defined FS_VALUE set "FS_VALUE=UNKNOWN"
call set "%FS_VAR%=!FS_VALUE!"
set "%~2=!FS_VALUE!"
exit /b


:NormalizePathNoTrailingSlash
set "%~2=%~1"
if not defined %~2 exit /b

set "NORM_WORK=!%~2!"
for %%P in ("!NORM_WORK!") do set "NORM_WORK=%%~fP"

if /i not "!NORM_WORK:~-2!"==":\" (
    if "!NORM_WORK:~-1!"=="\" set "NORM_WORK=!NORM_WORK:~0,-1!"
)

set "%~2=!NORM_WORK!"
exit /b


:ParseArgs
if "%~1"=="" exit /b 0

set "PARSE_ARG=%~1"

if "!EXPECT_GLOBAL_VALUE!"=="1" (
    set "GLOBAL_PATH=%~1"
    if "!GLOBAL_PATH:~0,1!"=="\"" if "!GLOBAL_PATH:~-1!"=="\"" set "GLOBAL_PATH=!GLOBAL_PATH:~1,-1!"
    set "EXPECT_GLOBAL_VALUE=0"
    shift
    goto :ParseArgs
)

if "!EXPECT_MODE_VALUE!"=="1" (
    set "LINK_MODE=%~1"
    if /i not "!LINK_MODE!"=="AUTO" if /i not "!LINK_MODE!"=="HARDLINK" if /i not "!LINK_MODE!"=="SYMLINK" (
        echo ERROR: Unsupported mode value "!LINK_MODE!". Use mode=auto^|hardlink^|symlink
        exit /b 1
    )
    set "EXPECT_MODE_VALUE=0"
    shift
    goto :ParseArgs
)

if /i "%~1"=="repair" set "RUN_MODE=repair" & shift & goto :ParseArgs
if /i "%~1"=="/repair" set "RUN_MODE=repair" & shift & goto :ParseArgs
if /i "%~1"=="--repair" set "RUN_MODE=repair" & shift & goto :ParseArgs
if /i "%~1"=="migrate" set "RUN_MODE=repair" & shift & goto :ParseArgs
if /i "%~1"=="/migrate" set "RUN_MODE=repair" & shift & goto :ParseArgs
if /i "%~1"=="--migrate" set "RUN_MODE=repair" & shift & goto :ParseArgs

if /i "%~1"=="verify" set "RUN_MODE=verify" & shift & goto :ParseArgs
if /i "%~1"=="/verify" set "RUN_MODE=verify" & shift & goto :ParseArgs
if /i "%~1"=="--verify" set "RUN_MODE=verify" & shift & goto :ParseArgs

if /i "%~1"=="help" set "RUN_MODE=help" & shift & goto :ParseArgs
if /i "%~1"=="/help" set "RUN_MODE=help" & shift & goto :ParseArgs
if /i "%~1"=="--help" set "RUN_MODE=help" & shift & goto :ParseArgs
if /i "%~1"=="/?" set "RUN_MODE=help" & shift & goto :ParseArgs

if /i "%~1"=="global" set "EXPECT_GLOBAL_VALUE=1" & shift & goto :ParseArgs
if /i "%~1"=="/global" set "EXPECT_GLOBAL_VALUE=1" & shift & goto :ParseArgs
if /i "%~1"=="--global" set "EXPECT_GLOBAL_VALUE=1" & shift & goto :ParseArgs

if /i "%~1"=="mode" set "EXPECT_MODE_VALUE=1" & shift & goto :ParseArgs
if /i "%~1"=="/mode" set "EXPECT_MODE_VALUE=1" & shift & goto :ParseArgs
if /i "%~1"=="--mode" set "EXPECT_MODE_VALUE=1" & shift & goto :ParseArgs

if /i "!PARSE_ARG:~0,7!"=="global=" (
    set "GLOBAL_PATH=!PARSE_ARG:~7!"
    if "!GLOBAL_PATH:~0,1!"=="\"" if "!GLOBAL_PATH:~-1!"=="\"" set "GLOBAL_PATH=!GLOBAL_PATH:~1,-1!"
    shift
    goto :ParseArgs
)

if /i "!PARSE_ARG:~0,8!"=="/global=" (
    set "GLOBAL_PATH=!PARSE_ARG:~8!"
    if "!GLOBAL_PATH:~0,1!"=="\"" if "!GLOBAL_PATH:~-1!"=="\"" set "GLOBAL_PATH=!GLOBAL_PATH:~1,-1!"
    shift
    goto :ParseArgs
)

if /i "!PARSE_ARG:~0,9!"=="--global=" (
    set "GLOBAL_PATH=!PARSE_ARG:~9!"
    if "!GLOBAL_PATH:~0,1!"=="\"" if "!GLOBAL_PATH:~-1!"=="\"" set "GLOBAL_PATH=!GLOBAL_PATH:~1,-1!"
    shift
    goto :ParseArgs
)

if /i "!PARSE_ARG:~0,5!"=="mode=" (
    set "LINK_MODE=!PARSE_ARG:~5!"
    if /i not "!LINK_MODE!"=="AUTO" if /i not "!LINK_MODE!"=="HARDLINK" if /i not "!LINK_MODE!"=="SYMLINK" (
        echo ERROR: Unsupported mode value "!LINK_MODE!". Use mode=auto^|hardlink^|symlink
        exit /b 1
    )
    shift
    goto :ParseArgs
)

if /i "!PARSE_ARG:~0,6!"=="/mode=" (
    set "LINK_MODE=!PARSE_ARG:~6!"
    if /i not "!LINK_MODE!"=="AUTO" if /i not "!LINK_MODE!"=="HARDLINK" if /i not "!LINK_MODE!"=="SYMLINK" (
        echo ERROR: Unsupported mode value "!LINK_MODE!". Use mode=auto^|hardlink^|symlink
        exit /b 1
    )
    shift
    goto :ParseArgs
)

if /i "!PARSE_ARG:~0,7!"=="--mode=" (
    set "LINK_MODE=!PARSE_ARG:~7!"
    if /i not "!LINK_MODE!"=="AUTO" if /i not "!LINK_MODE!"=="HARDLINK" if /i not "!LINK_MODE!"=="SYMLINK" (
        echo ERROR: Unsupported mode value "!LINK_MODE!". Use mode=auto^|hardlink^|symlink
        exit /b 1
    )
    shift
    goto :ParseArgs
)

echo ERROR: Unknown argument "%~1"
echo Use --help for usage.
exit /b 1


:Usage
echo.
echo Usage:
echo   %~nx0 [verify^|repair] [global^=PATH ^| global PATH] [mode^=auto^|hardlink^|symlink ^| mode VALUE]
echo.
echo Examples:
echo   %~nx0
echo   %~nx0 --help
echo   %~nx0 "global _MODELS_"
echo   %~nx0 "global=_MODELS_"
echo   %~nx0 "global=D:\AI\_global_models"
echo   %~nx0 global "D:\AI Models\_MODELS_"
echo   %~nx0 /global=D:\AI\_global_models /mode=auto
echo   %~nx0 mode=hardlink
echo   %~nx0 verify "global=D:\AI\_global_models"
echo.
echo Notes:
echo   mode=auto chooses hardlink on same NTFS volume, otherwise symlink.
echo   If global folder changes, existing files from default _global_models are migrated first (same-volume safe path).
echo   No copy fallback is used; link failure restores original source path.
echo.
exit /b 0


:MaybeMigrateLegacyGlobalStore
set "MIGRATE_LEGACY_NEEDED=0"

if /i "!GLOBAL_PATH_NORM!"=="!LEGACY_GLOBAL_PATH_NORM!" exit /b
if not exist "!LEGACY_GLOBAL_PATH_NORM!" exit /b

for %%S in ("!LEGACY_GLOBAL_PATH_NORM!") do set "MIG_OLD_DRIVE=%%~dS"
for %%D in ("!GLOBAL_PATH_NORM!") do set "MIG_NEW_DRIVE=%%~dD"

if /i not "!MIG_OLD_DRIVE!"=="!MIG_NEW_DRIVE!" (
    echo NOTICE: Global folder changed across volumes.
    echo NOTICE: Automatic legacy-folder migration is skipped for safety:
    echo         !LEGACY_GLOBAL_PATH_NORM!  --^>  !GLOBAL_PATH_NORM!
    echo NOTICE: Existing links from old global folder remain valid but are not relocated automatically.
    echo.
    exit /b
)

if not exist "!GLOBAL_PATH_NORM!" mkdir "!GLOBAL_PATH_NORM!"

echo Migrating existing global store:
echo   from: !LEGACY_GLOBAL_PATH_NORM!
echo   to  : !GLOBAL_PATH_NORM!

robocopy "!LEGACY_GLOBAL_PATH_NORM!" "!GLOBAL_PATH_NORM!" /E /MOVE /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 (
    echo WARNING: Legacy global-store migration reported errors.
    echo          You can re-run after checking folder permissions.
    echo.
    exit /b
)

call :PruneEmptyPath "!LEGACY_GLOBAL_PATH_NORM!"
rd "!LEGACY_GLOBAL_PATH_NORM!" 2>nul

echo Legacy global-store migration complete.
echo.
exit /b


:PruneEmptyPath
set "PRUNE_ROOT=%~1"
if not defined PRUNE_ROOT exit /b
if not exist "!PRUNE_ROOT!" exit /b

for /f "delims=" %%D in ('dir "!PRUNE_ROOT!" /s /b /ad 2^>nul ^| sort /R') do (
    if /i not "%%~fD"=="!PRUNE_ROOT!" rd "%%~fD" 2>nul
)

exit /b


:DetectCategory
REM Best-effort category detection from the source path.
set "CATEGORY=Other"
set "P=%~1"

call :CategoryMatch "Checkpoints" "\checkpoints\" "\checkpoint\" "\stable-diffusion\" "\models\stable-diffusion\"
call :CategoryMatch "LoRA" "\loras\" "\lora\" "\lycoris\" "\lora_training\" "\_lora_"
call :CategoryMatch "ControlNet" "\controlnet\" "\control_net\" "\openpose\" "\midas\" "\depth\"
call :CategoryMatch "VAE" "\vae\" "\vae-approx\" "\vae_approx\"
call :CategoryMatch "TextEncoders" "\text_encoders\" "\text-encoders\" "\text_encoder\" "\clip\" "\t5\" "\bert\"
call :CategoryMatch "CLIPVision" "\clip_vision\" "\clip-vision\"
call :CategoryMatch "UNet" "\unet\" "\diffusion_models\" "\diffusion-models\"
call :CategoryMatch "Upscale" "\upscale_models\" "\upscale-models\" "\upscalers\" "\esrgan\" "\realesrgan\" "\gfpgan\" "\ldsr\" "\swinir\" "\codeformer\"
call :CategoryMatch "Embeddings" "\embeddings\" "\embedding\" "\textual_inversion\" "\textual-inversion\"
call :CategoryMatch "Hypernetworks" "\hypernetworks\" "\hypernetwork\"
call :CategoryMatch "AudioEncoders" "\audio_encoders\" "\audio-encoders\"
call :CategoryMatch "FrameInterpolation" "\frame_interpolation\" "\frame-interpolation\" "\rife\"
call :CategoryMatch "GLIGEN" "\gligen\"
call :CategoryMatch "Photomaker" "\photomaker\"
call :CategoryMatch "StyleModels" "\style_models\" "\style-models\"
call :CategoryMatch "ModelPatches" "\model_patches\" "\model-patches\"
call :CategoryMatch "OpticalFlow" "\optical_flow\" "\optical-flow\"
call :CategoryMatch "GGUF" "\gguf\" "\llm\" "\llms\"

exit /b


:CategoryMatch
if /i not "!CATEGORY!"=="Other" exit /b

set "CAT=%~1"
shift

:CategoryMatchLoop
if "%~1"=="" exit /b

if /i not "!P:%~1=!"=="!P!" (
    set "CATEGORY=!CAT!"
    exit /b
)

shift
goto :CategoryMatchLoop


:Spinner
REM Single-line progress redraw for long-running scan/link/migration loops.
set /a SPIN=(SPIN + 1) %% 4
if !SPIN!==0 set "ICON=|"
if !SPIN!==1 set "ICON=/"
if !SPIN!==2 set "ICON=-"
if !SPIN!==3 set "ICON=\"

set "AI_ICON=!ICON!"
set "AI_TEXT=%~1"

powershell -NoProfile -Command "[Console]::Write(([char]13) + '[' + $env:AI_ICON + '] ' + $env:AI_TEXT + '                    ')"
exit /b


:SpinnerFlush
REM Clear the spinner line before printing normal multi-line output.
powershell -NoProfile -Command "[Console]::Write(([char]13) + (' ' * 160) + ([char]13))"
exit /b


:FormatSeconds
set /a FS_TOTAL=%~1
set /a FS_H=FS_TOTAL/3600
set /a FS_M=(FS_TOTAL%%3600)/60
set /a FS_S=FS_TOTAL%%60

if !FS_H! gtr 0 (
    set "%~2=!FS_H!h !FS_M!m !FS_S!s"
) else if !FS_M! gtr 0 (
    set "%~2=!FS_M!m !FS_S!s"
) else (
    set "%~2=!FS_S!s"
)
exit /b


:RandomScanMessage
set /a MSG=%RANDOM% %% 10
if "%MSG%"=="0" echo Summoning the model goblins...
if "%MSG%"=="1" echo Searching for forgotten neural networks...
if "%MSG%"=="2" echo Looking behind ComfyUI's couch cushions...
if "%MSG%"=="3" echo Teaching hamsters to count GGUF files...
if "%MSG%"=="4" echo Politely asking Windows where it hid your models...
if "%MSG%"=="5" echo Measuring the weight of your AI addiction...
if "%MSG%"=="6" echo Calculating potential SSD liberation...
if "%MSG%"=="7" echo Inspecting suspiciously large safetensors...
if "%MSG%"=="8" echo Following breadcrumb trails left by Stable Diffusion...
if "%MSG%"=="9" echo Checking whether final_final_v7_FIXED.gguf is really final...
exit /b


:RandomHashMessage
set /a MSG=%RANDOM% %% 8
if "%MSG%"=="0" echo Convincing duplicate models they are actually identical...
if "%MSG%"=="1" echo Performing advanced neural archaeology...
if "%MSG%"=="2" echo Comparing suspiciously similar safetensors...
if "%MSG%"=="3" echo Asking hashes to reveal their true identity...
if "%MSG%"=="4" echo No GPUs will be harmed during this process...
if "%MSG%"=="5" echo This may take a while, especially if you downloaded the entire internet...
if "%MSG%"=="6" echo Consulting the ancient checksum scrolls...
if "%MSG%"=="7" echo Separating twins from evil twins...
exit /b


:RandomExecuteMessage
set /a MSG=%RANDOM% %% 8
if "%MSG%"=="0" echo Preparing hardlink wizardry...
if "%MSG%"=="1" echo Relocating models to their new homeland...
if "%MSG%"=="2" echo Negotiating peace between duplicate checkpoints...
if "%MSG%"=="3" echo Opening portals to the global model dimension...
if "%MSG%"=="4" echo Asking NTFS very politely for hardlinks...
if "%MSG%"=="5" echo Uniting models under one banner...
if "%MSG%"=="6" echo Rehousing tensor beasts...
if "%MSG%"=="7" echo Performing careful storage surgery...
echo.
exit /b


:MigrateMalformedGlobalIds
REM Repair bad model-folder names and malformed ID folders inside _global_models.
set /a MIG_SCANNED=0
set /a MIG_FIXED=0
set /a MIG_REUSED=0
set /a MIG_ERRORS=0
set /a MIG_PRUNED=0
set /a MIG_HEARTBEAT=25

if not exist "!GLOBAL_PATH_NORM!" (
    echo Cleanup: Global folder not found. Nothing to migrate.
    exit /b
)

echo Cleanup: Checking existing global model names and IDs...

for /r "!GLOBAL_PATH_NORM!" %%F in (%MODEL_EXTENSIONS%) do (
    set /a MIG_SCANNED+=1
    set /a MHB=MIG_SCANNED %% MIG_HEARTBEAT
    if !MHB!==0 call :Spinner "Cleanup... !MIG_SCANNED! scanned, !MIG_FIXED! migrated, !MIG_REUSED! reused, !MIG_ERRORS! errors"

    set "FILE=%%~fF"
    set "REL=!FILE:!GLOBAL_PATH_NORM!\=!"

    for /f "tokens=1,2,3,4,* delims=\" %%A in ("!REL!") do (
        set "CAT=%%A"
        set "MODEL=%%B"
        set "ID=%%C"
        set "FNAME=%%D"
    )

    if not defined CAT (
        set /a MIG_ERRORS+=1
    ) else if not defined MODEL (
        set /a MIG_ERRORS+=1
    ) else if not defined ID (
        set /a MIG_ERRORS+=1
    ) else if not defined FNAME (
        set /a MIG_ERRORS+=1
    ) else (
        REM Folder name should match file basename; ID should be size_* or SHA256.
        for %%N in ("!FNAME!") do set "EXPECTED_MODEL=%%~nN"
        set "NEW_MODEL=!MODEL!"
        if /i not "!MODEL!"=="!EXPECTED_MODEL!" set "NEW_MODEL=!EXPECTED_MODEL!"

        call :IsValidModelId "!ID!"
        set "NEW_ID=!ID!"
        if "!ID_VALID!"=="0" (
            call :ComputeSha256 "%%~fF"
            set "NEW_ID=!HASH_RESULT!"

            if not defined NEW_ID (
                echo ERROR: Cleanup hash failed: !FILE!
                set /a MIG_ERRORS+=1
            )
        )

        if defined NEW_ID (
            set "NEW_DST=!GLOBAL_PATH_NORM!\!CAT!\!NEW_MODEL!\!NEW_ID!\!FNAME!"
            if /i "!NEW_DST!"=="!FILE!" (
                rem already normalized
            ) else if exist "!NEW_DST!" (
                del "!FILE!" >nul
                if errorlevel 1 (
                    echo ERROR: Cleanup delete failed: !FILE!
                    set /a MIG_ERRORS+=1
                ) else (
                    set /a MIG_REUSED+=1
                    for %%D in ("%%~dpF") do rd "%%~fD" 2>nul
                )
            ) else (
                for %%D in ("!NEW_DST!") do if not exist "%%~dpD" mkdir "%%~dpD"
                move /y "!FILE!" "!NEW_DST!" >nul
                if errorlevel 1 (
                    echo ERROR: Cleanup move failed: !FILE!
                    set /a MIG_ERRORS+=1
                ) else (
                    set /a MIG_FIXED+=1
                    for %%D in ("%%~dpF") do rd "%%~fD" 2>nul
                )
            )
        )
    )

    set "CAT="
    set "MODEL="
    set "ID="
    set "FNAME="
    set "EXPECTED_MODEL="
    set "NEW_MODEL="
    set "NEW_ID="
)

call :PruneEmptyGlobalDirs
call :SpinnerFlush

echo Cleanup scanned      : !MIG_SCANNED!
echo Cleanup migrated     : !MIG_FIXED!
echo Cleanup reused       : !MIG_REUSED!
echo Cleanup pruned dirs  : !MIG_PRUNED!
echo Cleanup errors       : !MIG_ERRORS!
echo.
exit /b


:PruneEmptyGlobalDirs
REM Remove empty directories bottom-up, but keep the _global_models root itself.
if not exist "!GLOBAL_PATH_NORM!" exit /b

for /f "delims=" %%D in ('dir "!GLOBAL_PATH_NORM!" /s /b /ad 2^>nul ^| sort /R') do (
    if /i not "%%~fD"=="!GLOBAL_PATH_NORM!" (
        rd "%%~fD" 2>nul
        if not exist "%%~fD\NUL" set /a MIG_PRUNED+=1
    )
)

exit /b


:IsValidModelId
REM Accept either legacy size_* IDs or normalized 64-char SHA256 folder names.
set "ID_VALID=0"
set "CHECK_ID=%~1"

if /i "!CHECK_ID:~0,5!"=="size_" (
    set "ID_VALID=1"
    exit /b
)

for /f %%V in ('powershell -NoProfile -Command "$id=$env:CHECK_ID; if ($id -match \"^[0-9a-fA-F]{64}$\") { Write-Output 1 } else { Write-Output 0 }"') do set "ID_VALID=%%V"
exit /b


:ComputeSha256
REM Hash helper used only when size-based grouping is not sufficient.
set "HASH_RESULT="
set "HASH_SRC=%~1"

for /f %%H in ('powershell -NoProfile -Command "$p=$env:HASH_SRC; try { (Get-FileHash -LiteralPath $p -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower() } catch { }"') do (
    set "HASH_RESULT=%%H"
    exit /b
)

exit /b
