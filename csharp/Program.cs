using System.ComponentModel;
using System.Diagnostics;
using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

var parsed = ParseArgs(args);
if (!parsed.Ok)
{
    Console.WriteLine($"ERROR: {parsed.Error}");
    PrintUsage();
    Environment.ExitCode = 1;
    return;
}

var options = parsed.Options!;
if (options.RunMode == RunMode.Help)
{
    PrintUsage();
    return;
}

var start = DateTimeOffset.UtcNow;
var cwd = NormalizePathNoTrailingSlash(Directory.GetCurrentDirectory());
var root = NormalizePathNoTrailingSlash(ToAbsolutePath(cwd, options.ScanRoot));
var globalPath = NormalizePathNoTrailingSlash(ToAbsolutePath(root, options.GlobalPath));

if (options.RunMode == RunMode.Normal)
{
    if (options.PromptPaths)
    {
        (root, globalPath) = PromptForPaths(root, globalPath);
    }
}

var legacyGlobalPath = NormalizePathNoTrailingSlash(Path.Combine(root, "_global_models"));
var foundLog = Path.Combine(root, "ai_model_globalizer_found_files.txt");
var verifyLog = Path.Combine(root, "ai_model_globalizer_verify_failures.txt");

if (options.Debug)
{
    TryDeleteFile(foundLog);
}
TryDeleteFile(verifyLog);

Console.WriteLine("==================================================");
Console.WriteLine("           AI MODEL GLOBALIZER (C#)");
Console.WriteLine("==================================================");
Console.WriteLine($"Root folder   : {root}");
Console.WriteLine($"Global folder : {globalPath}");
Console.WriteLine($"Link mode     : {options.LinkMode}");
Console.WriteLine($"Debug logging : {(options.Debug ? "on" : "off")}");
Console.WriteLine();

try
{
    MaybeMigrateLegacyGlobalStore(legacyGlobalPath, globalPath);

    switch (options.RunMode)
    {
        case RunMode.Verify:
            RunVerify(root, globalPath, verifyLog, start);
            break;
        case RunMode.Repair:
            RunRepair(globalPath, start);
            break;
        default:
            RunNormal(root, globalPath, foundLog, options, start);
            break;
    }
}
catch (Exception ex)
{
    Console.WriteLine();
    Console.WriteLine("==================================================");
    Console.WriteLine("ERROR");
    Console.WriteLine("==================================================");
    Console.WriteLine(ex.Message);
    Console.WriteLine();
    Console.WriteLine(ex);
    Environment.ExitCode = 1;
}
finally
{
    PauseBeforeExitIfNeeded(options);
}

static void RunNormal(string root, string globalPath, string foundLog, Options options, DateTimeOffset started)
{
    Console.WriteLine("Scanning first. Nothing will be changed yet.");
    Console.WriteLine("(Large folders can take time. Live scan progress is shown below.)");
    var reparseDirs = BuildReparseList(root);
    Console.WriteLine($"Reparse dirs found: {reparseDirs.Count}");
    Console.WriteLine();

    var scan = ScanModelFiles(
        root,
        globalPath,
        reparseDirs,
        includeAlreadyGlobalized: false,
        foundLogPath: options.Debug ? foundLog : null);
    var skippedTotal = scan.SkippedAlready + scan.SkippedGlobal + scan.SkippedIgnored + scan.SkippedReparse;

    if (scan.Candidates.Count == 0)
    {
        Console.WriteLine("No new model files found.");
        Console.WriteLine($"Skipped total       : {skippedTotal}");
        Console.WriteLine($"Model files checked : {scan.ScannedMatches}");
        return;
    }

    Console.WriteLine("Preparing plan...");
    var prep = BuildOperations(scan.Candidates, globalPath);
    var scanSeconds = (long)(DateTimeOffset.UtcNow - started).TotalSeconds;

    Console.WriteLine("==================================================");
    Console.WriteLine("                  SCAN RESULT");
    Console.WriteLine("==================================================");
    Console.WriteLine($"Model files to globalize        : {scan.Candidates.Count}");
    Console.WriteLine($"Destination groups              : {prep.UniqueGroups}");
    Console.WriteLine($"Possible duplicate files        : {prep.DuplicateCandidates}");
    Console.WriteLine($"Files checked by content hash   : {prep.HashNeeded}");
    Console.WriteLine($"Skipped total                   : {skippedTotal}");
    Console.WriteLine($"Model files checked             : {scan.ScannedMatches}");
    Console.WriteLine($"Scan time                       : {FormatSeconds(scanSeconds)}");
    Console.WriteLine();
    if (options.Debug)
    {
        Console.WriteLine($"Found-file list: {foundLog}");
    }
    else
    {
        Console.WriteLine("Found-file list: disabled (use debug to enable)");
    }
    Console.WriteLine();

    Console.WriteLine("E = Execute linking");
    Console.WriteLine("Q = Quit without changing anything");
    Console.WriteLine();
    Console.Write("Selection, then press ENTER: ");
    var action = Console.ReadLine()?.Trim();
    if (!string.Equals(action, "E", StringComparison.OrdinalIgnoreCase))
    {
        Console.WriteLine("Cancelled. No files were modified.");
        return;
    }

    Directory.CreateDirectory(globalPath);
    var exec = ExecuteOperations(prep.Operations, options.LinkMode);
    var totalSeconds = (long)(DateTimeOffset.UtcNow - started).TotalSeconds;

    Console.WriteLine();
    Console.WriteLine("==================================================");
    Console.WriteLine("Finished");
    Console.WriteLine("==================================================");
    Console.WriteLine($"Processed             : {exec.Processed}");
    Console.WriteLine($"Moved to global       : {exec.Moved}");
    Console.WriteLine($"Reused                : {exec.Reused}");
    Console.WriteLine($"Linked                : {exec.Linked}");
    Console.WriteLine($"Hardlinks             : {exec.Hardlinked}");
    Console.WriteLine($"Symlinks              : {exec.Symlinked}");
    Console.WriteLine($"Restored originals    : {exec.Restored}");
    Console.WriteLine($"Errors                : {exec.Errors}");
    Console.WriteLine($"Total time elapsed    : {FormatSeconds(totalSeconds)}");
}

static void RunVerify(string root, string globalPath, string verifyLog, DateTimeOffset started)
{
    var reparseDirs = BuildReparseList(root);
    var scan = ScanModelFiles(root, globalPath, reparseDirs, includeAlreadyGlobalized: true, foundLogPath: null);

    var linked = 0;
    var missing = 0;
    foreach (var file in scan.AllFilesChecked)
    {
        if (IsAlreadyGlobalized(file, globalPath))
        {
            linked++;
        }
        else
        {
            missing++;
            File.AppendAllText(verifyLog, file + Environment.NewLine);
        }
    }

    var totalSeconds = (long)(DateTimeOffset.UtcNow - started).TotalSeconds;
    Console.WriteLine($"Verify checked         : {scan.AllFilesChecked.Count}");
    Console.WriteLine($"Verify linked          : {linked}");
    Console.WriteLine($"Verify missing         : {missing}");
    Console.WriteLine($"Verify skipped global  : {scan.SkippedGlobal}");
    Console.WriteLine($"Verify skipped ignored : {scan.SkippedIgnored}");
    Console.WriteLine($"Verify skipped reparse : {scan.SkippedReparse}");
    Console.WriteLine($"Verify time            : {FormatSeconds(totalSeconds)}");
    Console.WriteLine($"Verify failure log     : {(missing > 0 ? verifyLog : "none")}");
}

static void RunRepair(string globalPath, DateTimeOffset started)
{
    Directory.CreateDirectory(globalPath);
    var cleanup = MigrateMalformedGlobalIds(globalPath);
    var totalSeconds = (long)(DateTimeOffset.UtcNow - started).TotalSeconds;

    Console.WriteLine($"Cleanup scanned      : {cleanup.Scanned}");
    Console.WriteLine($"Cleanup migrated     : {cleanup.Fixed}");
    Console.WriteLine($"Cleanup reused       : {cleanup.Reused}");
    Console.WriteLine($"Cleanup pruned dirs  : {cleanup.Pruned}");
    Console.WriteLine($"Cleanup errors       : {cleanup.Errors}");
    Console.WriteLine($"Repair-only run finished in {FormatSeconds(totalSeconds)}");
}

static ScanResult ScanModelFiles(string root, string globalPath, HashSet<string> reparseDirs, bool includeAlreadyGlobalized, string? foundLogPath)
{
    var candidates = new List<Candidate>();
    var allChecked = new List<string>();
    var skippedGlobal = 0;
    var skippedAlready = 0;
    var skippedIgnored = 0;
    var skippedReparse = 0;
    var scannedMatches = 0;
    var dirsVisited = 0;
    var progressShown = false;

    var stack = new Stack<string>();
    stack.Push(root);

    while (stack.Count > 0)
    {
        var current = stack.Pop();
        dirsVisited++;
        if (dirsVisited % 50 == 0)
        {
            var skippedTotal = skippedAlready + skippedGlobal + skippedIgnored + skippedReparse;
            PrintScanProgress(dirsVisited, scannedMatches, candidates.Count, skippedTotal);
            progressShown = true;
        }

        IEnumerable<string> dirs;
        IEnumerable<string> files;
        try
        {
            dirs = Directory.EnumerateDirectories(current);
            files = Directory.EnumerateFiles(current);
        }
        catch
        {
            continue;
        }

        foreach (var dir in dirs)
        {
            var full = NormalizePathNoTrailingSlash(Path.GetFullPath(dir));
            if (PathEqualsOrUnder(full, globalPath)) { skippedGlobal++; continue; }
            if (IsIgnoredFolder(full)) { skippedIgnored++; continue; }
            if (reparseDirs.Contains(full)) { skippedReparse++; continue; }
            stack.Push(full);
        }

        foreach (var file in files)
        {
            if (!IsModelExtension(Path.GetExtension(file))) continue;
            scannedMatches++;
            if (scannedMatches % 100 == 0)
            {
                var skippedTotal = skippedAlready + skippedGlobal + skippedIgnored + skippedReparse;
                PrintScanProgress(dirsVisited, scannedMatches, candidates.Count, skippedTotal);
                progressShown = true;
            }

            var full = Path.GetFullPath(file);
            if (PathEqualsOrUnder(full, globalPath)) { skippedGlobal++; continue; }
            if (IsIgnoredFolder(full)) { skippedIgnored++; continue; }
            if (IsInReparsePath(full, reparseDirs)) { skippedReparse++; continue; }

            allChecked.Add(full);

            if (!includeAlreadyGlobalized && IsAlreadyGlobalized(full, globalPath))
            {
                skippedAlready++;
                continue;
            }

            var info = new FileInfo(full);
            var candidate = new Candidate(DetectCategory(full), Path.GetFileNameWithoutExtension(info.Name), info.Name, info.Length, info.FullName);
            candidates.Add(candidate);

            if (!string.IsNullOrWhiteSpace(foundLogPath))
            {
                File.AppendAllText(foundLogPath, $"{candidate.Category}\t{candidate.SourcePath}{Environment.NewLine}");
            }
        }
    }

    if (progressShown)
    {
        Console.WriteLine();
    }

    return new ScanResult(candidates, allChecked, skippedGlobal, skippedAlready, skippedIgnored, skippedReparse, scannedMatches);
}

static void PrintScanProgress(int dirsVisited, int modelMatches, int candidates, int skippedTotal)
{
    var spinner = GetSpinnerFrame(dirsVisited + modelMatches);
    Console.Write($"\r{spinner} Scanning... dirs:{dirsVisited} models:{modelMatches} candidates:{candidates} skipped:{skippedTotal}   ");
}

static OperationPrep BuildOperations(List<Candidate> candidates, string globalPath)
{
    var ops = new List<Operation>();

    var groups = candidates
        .GroupBy(c => $"{c.Category}\t{c.ModelName}\t{c.FileName}\t{c.Size}", StringComparer.OrdinalIgnoreCase)
        .ToList();

    var uniqueGroups = groups.Count;
    var duplicateCandidates = groups.Where(g => g.Count() > 1).Sum(g => g.Count());
    var hashNeeded = duplicateCandidates;
    var groupsDone = 0;
    var hashesDone = 0;
    var progressShown = false;

    foreach (var group in groups)
    {
        var items = group.ToList();
        groupsDone++;
        PrintPlanProgress(groupsDone, uniqueGroups, hashesDone, hashNeeded, null);
        progressShown = true;

        foreach (var item in items)
        {
            var id = $"size_{item.Size}";
            if (items.Count > 1)
            {
                hashesDone++;
                id = ComputeSha256WithProgress(item.SourcePath, hashesDone, hashNeeded);
                progressShown = true;
            }

            var destination = Path.Combine(globalPath, item.Category, item.ModelName, id, item.FileName);
            ops.Add(new Operation(item.SourcePath, destination));
        }
    }

    if (progressShown)
    {
        Console.WriteLine();
    }

    return new OperationPrep(ops, uniqueGroups, duplicateCandidates, hashNeeded);
}

static void PrintPlanProgress(int groupsDone, int totalGroups, int hashesDone, int totalHashes, string? currentHashFile)
{
    var spinner = GetSpinnerFrame(groupsDone + hashesDone);
    var hashText = totalHashes > 0 ? $" hashes:{hashesDone}/{totalHashes}" : string.Empty;
    var fileText = string.IsNullOrWhiteSpace(currentHashFile) ? string.Empty : $" file:{currentHashFile}";
    Console.Write($"\r{spinner} Preparing plan... groups:{groupsDone}/{totalGroups}{hashText}{fileText}   ");
}

static string ComputeSha256WithProgress(string path, int hashIndex, int hashTotal)
{
    var fileName = Path.GetFileName(path);
    var info = new FileInfo(path);
    var totalBytes = Math.Max(info.Length, 1);
    var readBytes = 0L;
    var lastUpdate = DateTimeOffset.MinValue;
    var buffer = new byte[4 * 1024 * 1024];

    using var stream = File.OpenRead(path);
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);

    while (true)
    {
        var read = stream.Read(buffer, 0, buffer.Length);
        if (read == 0) break;

        hash.AppendData(buffer, 0, read);
        readBytes += read;

        var now = DateTimeOffset.UtcNow;
        if ((now - lastUpdate).TotalMilliseconds >= 250)
        {
            var percent = Math.Min(100, (int)(readBytes * 100 / totalBytes));
            PrintHashProgress(hashIndex, hashTotal, percent, fileName);
            lastUpdate = now;
        }
    }

    PrintHashProgress(hashIndex, hashTotal, 100, fileName);
    return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
}

static void PrintHashProgress(int hashIndex, int hashTotal, int percent, string fileName)
{
    var spinner = GetSpinnerFrame(hashIndex + percent);
    Console.Write($"\r{spinner} Preparing plan... hashing:{hashIndex}/{hashTotal} current:{percent}% file:{fileName}   ");
}

static char GetSpinnerFrame(int value)
{
    return (value & 3) switch
    {
        0 => '|',
        1 => '/',
        2 => '-',
        _ => '\\'
    };
}

static ExecutionResult ExecuteOperations(List<Operation> operations, LinkMode mode)
{
    var processed = 0;
    var linked = 0;
    var errors = 0;
    var moved = 0;
    var reused = 0;
    var hardlinked = 0;
    var symlinked = 0;
    var restored = 0;

    foreach (var op in operations)
    {
        processed++;

        var movedNow = false;
        try
        {
            var targetDir = Path.GetDirectoryName(op.DestinationPath);
            if (!string.IsNullOrWhiteSpace(targetDir)) Directory.CreateDirectory(targetDir);

            if (File.Exists(op.DestinationPath))
            {
                reused++;
            }
            else
            {
                File.Move(op.SourcePath, op.DestinationPath);
                moved++;
                movedNow = true;
            }

            if (!movedNow && File.Exists(op.SourcePath))
            {
                File.Delete(op.SourcePath);
            }

            if (TryCreateFileLink(op.SourcePath, op.DestinationPath, mode, out var effectiveMode, out var linkError))
            {
                linked++;
                if (effectiveMode == LinkMode.Hardlink) hardlinked++;
                if (effectiveMode == LinkMode.Symlink) symlinked++;
                continue;
            }

            errors++;
            Console.WriteLine($"ERROR: {linkError} :: {op.SourcePath}");

            if (movedNow) TryRestoreByMove(op.DestinationPath, op.SourcePath, ref restored);
            else TryRestoreByCopy(op.DestinationPath, op.SourcePath, ref restored);
        }
        catch (Exception ex)
        {
            errors++;
            Console.WriteLine($"ERROR: {op.SourcePath} :: {ex.Message}");
            if (movedNow) TryRestoreByMove(op.DestinationPath, op.SourcePath, ref restored);
        }
    }

    return new ExecutionResult(processed, moved, reused, linked, hardlinked, symlinked, restored, errors);
}

static CleanupResult MigrateMalformedGlobalIds(string globalPath)
{
    var scanned = 0;
    var fixedCount = 0;
    var reused = 0;
    var errors = 0;

    foreach (var file in EnumerateFilesSafe(globalPath))
    {
        if (!IsModelExtension(Path.GetExtension(file))) continue;

        scanned++;
        var rel = Path.GetRelativePath(globalPath, file);
        var parts = rel.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 4) { errors++; continue; }

        var category = parts[0];
        var model = parts[1];
        var id = parts[2];
        var fileName = Path.GetFileName(file);

        var expectedModel = Path.GetFileNameWithoutExtension(fileName);
        var newModel = string.Equals(model, expectedModel, StringComparison.OrdinalIgnoreCase) ? model : expectedModel;
        var newId = IsValidModelId(id) ? id : ComputeSha256(file);

        var newDestination = Path.Combine(globalPath, category, newModel, newId, fileName);
        if (string.Equals(NormalizePathNoTrailingSlash(file), NormalizePathNoTrailingSlash(newDestination), StringComparison.OrdinalIgnoreCase))
        {
            continue;
        }

        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(newDestination)!);
            if (File.Exists(newDestination))
            {
                File.Delete(file);
                reused++;
            }
            else
            {
                File.Move(file, newDestination);
                fixedCount++;
            }
        }
        catch
        {
            errors++;
        }
    }

    var pruned = PruneEmptyDirs(globalPath);
    return new CleanupResult(scanned, fixedCount, reused, pruned, errors);
}

static void MaybeMigrateLegacyGlobalStore(string legacyGlobalPath, string globalPath)
{
    if (string.Equals(legacyGlobalPath, globalPath, StringComparison.OrdinalIgnoreCase)) return;
    if (!Directory.Exists(legacyGlobalPath)) return;

    if (!IsSameVolume(legacyGlobalPath, globalPath))
    {
        Console.WriteLine("NOTICE: Global folder changed across volumes.");
        Console.WriteLine("NOTICE: Automatic legacy-folder migration is skipped for safety.");
        Console.WriteLine();
        return;
    }

    Directory.CreateDirectory(globalPath);
    var files = EnumerateFilesSafe(legacyGlobalPath).ToList();

    Console.WriteLine("Migrating existing global store:");
    Console.WriteLine($"  from: {legacyGlobalPath}");
    Console.WriteLine($"  to  : {globalPath}");
    Console.WriteLine($"Files queued for migration: {files.Count}");

    foreach (var oldFile in files)
    {
        var rel = Path.GetRelativePath(legacyGlobalPath, oldFile);
        var newFile = Path.Combine(globalPath, rel);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(newFile)!);
            if (File.Exists(newFile)) File.Delete(oldFile);
            else File.Move(oldFile, newFile);
        }
        catch
        {
            // best effort
        }
    }

    PruneEmptyDirs(legacyGlobalPath);
    try { Directory.Delete(legacyGlobalPath, recursive: false); } catch { }

    Console.WriteLine("Legacy global-store migration complete.");
    Console.WriteLine();
}

static bool TryCreateFileLink(string sourcePath, string destinationPath, LinkMode configuredMode, out LinkMode effectiveMode, out string error)
{
    effectiveMode = configuredMode;

    if (configuredMode == LinkMode.Auto)
    {
        effectiveMode = CanUseHardlink(sourcePath, destinationPath) ? LinkMode.Hardlink : LinkMode.Symlink;
    }

    if (effectiveMode == LinkMode.Hardlink)
    {
        if (!CanUseHardlink(sourcePath, destinationPath))
        {
            error = "Hardlink not supported for this source/destination (needs same NTFS volume)";
            return false;
        }

        if (CreateHardLink(sourcePath, destinationPath, IntPtr.Zero))
        {
            error = string.Empty;
            return true;
        }

        error = "Hardlink creation failed";
        return false;
    }

    try
    {
        File.CreateSymbolicLink(sourcePath, destinationPath);
        error = string.Empty;
        return true;
    }
    catch (Exception ex)
    {
        var win32 = Marshal.GetLastWin32Error();
        error = win32 != 0 ? new Win32Exception(win32).Message : $"Symlink creation failed: {ex.Message}";
        return false;
    }
}

static bool CanUseHardlink(string sourcePath, string destinationPath)
{
    if (!IsSameVolume(sourcePath, destinationPath)) return false;

    var driveRoot = Path.GetPathRoot(Path.GetFullPath(sourcePath));
    if (string.IsNullOrWhiteSpace(driveRoot)) return false;

    try
    {
        var drive = new DriveInfo(driveRoot);
        return string.Equals(drive.DriveFormat, "NTFS", StringComparison.OrdinalIgnoreCase);
    }
    catch
    {
        return false;
    }
}

static bool IsAlreadyGlobalized(string sourcePath, string globalPath)
{
    if (PathEqualsOrUnder(sourcePath, globalPath)) return true;

    if (HasMultipleHardlinks(sourcePath))
    {
        foreach (var hardlink in ListHardLinks(sourcePath))
        {
            if (PathEqualsOrUnder(hardlink, globalPath)) return true;
        }
    }

    try
    {
        var info = new FileInfo(sourcePath);
        if (info.Exists && info.Attributes.HasFlag(FileAttributes.ReparsePoint) && !string.IsNullOrWhiteSpace(info.LinkTarget))
        {
            var target = ResolveLinkTarget(sourcePath, info.LinkTarget!);
            if (!string.IsNullOrWhiteSpace(target) && PathEqualsOrUnder(target, globalPath)) return true;
        }
    }
    catch
    {
        // ignored
    }

    return false;
}

static bool HasMultipleHardlinks(string path)
{
    try
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (GetFileInformationByHandle(stream.SafeFileHandle, out var fileInfo))
        {
            return fileInfo.NumberOfLinks > 1;
        }
    }
    catch
    {
        // ignored
    }

    return false;
}

static IEnumerable<string> ListHardLinks(string sourcePath)
{
    var result = RunProcessCapture("fsutil", $"hardlink list \"{sourcePath}\"");
    if (result.ExitCode != 0) yield break;

    var lines = result.Output
        .Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries)
        .Select(l => l.Trim());

    foreach (var line in lines)
    {
        if (line.Length == 0) continue;
        if (line.StartsWith("Hardlink", StringComparison.OrdinalIgnoreCase)) continue;
        if (line.StartsWith("\\", StringComparison.OrdinalIgnoreCase) || line.Contains(":\\", StringComparison.OrdinalIgnoreCase))
        {
            yield return NormalizePathNoTrailingSlash(Path.GetFullPath(line));
        }
    }
}

static ProcessResult RunProcessCapture(string fileName, string arguments)
{
    try
    {
        var psi = new ProcessStartInfo(fileName, arguments)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        using var process = Process.Start(psi);
        if (process is null) return new ProcessResult(1, string.Empty);

        var output = process.StandardOutput.ReadToEnd() + Environment.NewLine + process.StandardError.ReadToEnd();
        process.WaitForExit();
        return new ProcessResult(process.ExitCode, output);
    }
    catch
    {
        return new ProcessResult(1, string.Empty);
    }
}

static HashSet<string> BuildReparseList(string root)
{
    var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    var stack = new Stack<string>();
    stack.Push(root);

    while (stack.Count > 0)
    {
        var current = stack.Pop();
        IEnumerable<string> dirs;
        try { dirs = Directory.EnumerateDirectories(current); }
        catch { continue; }

        foreach (var dir in dirs)
        {
            try
            {
                var attr = File.GetAttributes(dir);
                var full = NormalizePathNoTrailingSlash(Path.GetFullPath(dir));
                if (attr.HasFlag(FileAttributes.ReparsePoint))
                {
                    set.Add(full);
                    continue;
                }

                stack.Push(full);
            }
            catch { }
        }
    }

    return set;
}

static bool IsInReparsePath(string path, HashSet<string> reparseDirs)
{
    var fullPath = NormalizePathNoTrailingSlash(Path.GetFullPath(path));
    return reparseDirs.Any(r => PathEqualsOrUnder(fullPath, r));
}

static string ResolveLinkTarget(string sourcePath, string target)
{
    try
    {
        if (Path.IsPathRooted(target)) return NormalizePathNoTrailingSlash(Path.GetFullPath(target));

        var parent = Path.GetDirectoryName(sourcePath) ?? Directory.GetCurrentDirectory();
        return NormalizePathNoTrailingSlash(Path.GetFullPath(Path.Combine(parent, target)));
    }
    catch
    {
        return string.Empty;
    }
}

static string DetectCategory(string path)
{
    var p = path.Replace('/', '\\').ToLowerInvariant();

    return MatchCategory(p,
        ("Checkpoints", new[] { "\\checkpoints\\", "\\checkpoint\\", "\\stable-diffusion\\", "\\models\\stable-diffusion\\" }),
        ("LoRA", new[] { "\\loras\\", "\\lora\\", "\\lycoris\\", "\\lora_training\\", "\\_lora_" }),
        ("ControlNet", new[] { "\\controlnet\\", "\\control_net\\", "\\openpose\\", "\\midas\\", "\\depth\\" }),
        ("VAE", new[] { "\\vae\\", "\\vae-approx\\", "\\vae_approx\\" }),
        ("TextEncoders", new[] { "\\text_encoders\\", "\\text-encoders\\", "\\text_encoder\\", "\\clip\\", "\\t5\\", "\\bert\\" }),
        ("CLIPVision", new[] { "\\clip_vision\\", "\\clip-vision\\" }),
        ("UNet", new[] { "\\unet\\", "\\diffusion_models\\", "\\diffusion-models\\" }),
        ("Upscale", new[] { "\\upscale_models\\", "\\upscale-models\\", "\\upscalers\\", "\\esrgan\\", "\\realesrgan\\", "\\gfpgan\\", "\\ldsr\\", "\\swinir\\", "\\codeformer\\" }),
        ("Embeddings", new[] { "\\embeddings\\", "\\embedding\\", "\\textual_inversion\\", "\\textual-inversion\\" }),
        ("Hypernetworks", new[] { "\\hypernetworks\\", "\\hypernetwork\\" }),
        ("AudioEncoders", new[] { "\\audio_encoders\\", "\\audio-encoders\\" }),
        ("FrameInterpolation", new[] { "\\frame_interpolation\\", "\\frame-interpolation\\", "\\rife\\" }),
        ("GLIGEN", new[] { "\\gligen\\" }),
        ("Photomaker", new[] { "\\photomaker\\" }),
        ("StyleModels", new[] { "\\style_models\\", "\\style-models\\" }),
        ("ModelPatches", new[] { "\\model_patches\\", "\\model-patches\\" }),
        ("OpticalFlow", new[] { "\\optical_flow\\", "\\optical-flow\\" }),
        ("GGUF", new[] { "\\gguf\\", "\\llm\\", "\\llms\\" }));
}

static string MatchCategory(string path, params (string category, string[] tokens)[] rules)
{
    foreach (var rule in rules)
    {
        foreach (var token in rule.tokens)
        {
            if (path.Contains(token, StringComparison.OrdinalIgnoreCase)) return rule.category;
        }
    }

    return "Other";
}

static bool IsModelExtension(string extension)
{
    return extension.Equals(".safetensors", StringComparison.OrdinalIgnoreCase)
        || extension.Equals(".gguf", StringComparison.OrdinalIgnoreCase)
        || extension.Equals(".ckpt", StringComparison.OrdinalIgnoreCase)
        || extension.Equals(".onnx", StringComparison.OrdinalIgnoreCase);
}

static bool IsIgnoredFolder(string path)
{
    var p = path.Replace('/', '\\');
    foreach (var name in GetIgnoredDirs())
    {
        if (p.Contains($"\\{name}\\", StringComparison.OrdinalIgnoreCase)) return true;
    }

    return false;
}

static string[] GetIgnoredDirs() =>
[
    "venv", ".venv", "site-packages", "node_modules", "__pycache__", "cache", "caches", "tmp", "temp",
    ".git", "logs", "output", "outputs", "samples", "test", "tests", "example", "examples"
];

static bool IsValidModelId(string id)
{
    if (id.StartsWith("size_", StringComparison.OrdinalIgnoreCase)) return true;
    if (id.Length != 64) return false;
    foreach (var c in id) if (!Uri.IsHexDigit(c)) return false;
    return true;
}

static string ComputeSha256(string path)
{
    using var stream = File.OpenRead(path);
    var hash = SHA256.HashData(stream);
    return Convert.ToHexString(hash).ToLowerInvariant();
}

static bool PathEqualsOrUnder(string path, string root)
{
    var fullPath = NormalizePathNoTrailingSlash(Path.GetFullPath(path));
    var fullRoot = NormalizePathNoTrailingSlash(Path.GetFullPath(root));

    return fullPath.Equals(fullRoot, StringComparison.OrdinalIgnoreCase)
        || fullPath.StartsWith(fullRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
        || fullPath.StartsWith(fullRoot + Path.AltDirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
}

static bool IsSameVolume(string a, string b)
{
    var ra = Path.GetPathRoot(Path.GetFullPath(a));
    var rb = Path.GetPathRoot(Path.GetFullPath(b));
    return string.Equals(ra, rb, StringComparison.OrdinalIgnoreCase);
}

static string ToAbsolutePath(string root, string value)
{
    return Path.IsPathRooted(value) ? value : Path.Combine(root, value);
}

static string NormalizePathNoTrailingSlash(string path)
{
    var full = Path.GetFullPath(path);
    if (full.Length == 3 && full[1] == ':' && full[2] == '\\') return full;
    return full.TrimEnd('\\', '/');
}

static IEnumerable<string> EnumerateFilesSafe(string root)
{
    var stack = new Stack<string>();
    stack.Push(root);

    while (stack.Count > 0)
    {
        var current = stack.Pop();

        IEnumerable<string> dirs;
        IEnumerable<string> files;
        try
        {
            dirs = Directory.EnumerateDirectories(current);
            files = Directory.EnumerateFiles(current);
        }
        catch
        {
            continue;
        }

        foreach (var file in files) yield return file;
        foreach (var dir in dirs) stack.Push(dir);
    }
}

static int PruneEmptyDirs(string root)
{
    var pruned = 0;
    if (!Directory.Exists(root)) return pruned;

    var dirs = Directory.EnumerateDirectories(root, "*", SearchOption.AllDirectories)
        .OrderByDescending(d => d.Length)
        .ToList();

    foreach (var dir in dirs)
    {
        try
        {
            if (!Directory.EnumerateFileSystemEntries(dir).Any())
            {
                Directory.Delete(dir);
                pruned++;
            }
        }
        catch { }
    }

    return pruned;
}

static void TryRestoreByMove(string destinationPath, string sourcePath, ref int restored)
{
    try
    {
        if (File.Exists(destinationPath) && !File.Exists(sourcePath))
        {
            File.Move(destinationPath, sourcePath);
            restored++;
        }
    }
    catch
    {
        Console.WriteLine($"ERROR: Restore failed: {sourcePath}");
    }
}

static void TryRestoreByCopy(string destinationPath, string sourcePath, ref int restored)
{
    try
    {
        if (File.Exists(destinationPath) && !File.Exists(sourcePath))
        {
            File.Copy(destinationPath, sourcePath);
            restored++;
        }
    }
    catch
    {
        Console.WriteLine($"ERROR: Restore failed: {sourcePath}");
    }
}

static void TryDeleteFile(string path)
{
    try
    {
        if (File.Exists(path)) File.Delete(path);
    }
    catch { }
}

static void PauseBeforeExitIfNeeded(Options options)
{
    if (options.RunMode != RunMode.Normal) return;
    if (!options.PromptPaths) return;
    if (Console.IsInputRedirected) return;

    Console.WriteLine();
    Console.Write("Press ENTER to exit...");
    Console.ReadLine();
}

static string FormatSeconds(long totalSeconds)
{
    if (totalSeconds < 0) totalSeconds = 0;
    var ts = TimeSpan.FromSeconds(totalSeconds);
    if (ts.TotalHours >= 1) return $"{(int)ts.TotalHours}h {ts.Minutes}m {ts.Seconds}s";
    if (ts.TotalMinutes >= 1) return $"{ts.Minutes}m {ts.Seconds}s";
    return $"{ts.Seconds}s";
}

static ParseResult ParseArgs(string[] args)
{
    var runMode = RunMode.Normal;
    var scanRoot = ".";
    var global = "_global_models";
    var linkMode = LinkMode.Auto;
    var debug = false;
    var promptPaths = true;
    var scanRootProvided = false;
    var expectGlobalValue = false;
    var expectScanValue = false;
    var expectModeValue = false;

    for (var i = 0; i < args.Length; i++)
    {
        var arg = args[i]?.Trim() ?? string.Empty;
        if (arg.Length == 0) continue;

        if (expectGlobalValue)
        {
            global = TrimWrappedQuotes(arg);
            expectGlobalValue = false;
            continue;
        }

        if (expectScanValue)
        {
            scanRoot = TrimWrappedQuotes(arg);
            scanRootProvided = true;
            expectScanValue = false;
            continue;
        }

        if (expectModeValue)
        {
            var parsedMode = ParseLinkMode(arg);
            if (parsedMode is null) return ParseResult.Fail($"Unsupported mode value '{arg}'. Use mode=auto|hardlink|symlink");
            linkMode = parsedMode.Value;
            expectModeValue = false;
            continue;
        }

        if (IsAny(arg, "help", "/help", "--help", "/?", "-h")) { runMode = RunMode.Help; continue; }
        if (IsAny(arg, "repair", "/repair", "--repair", "migrate", "/migrate", "--migrate")) { runMode = RunMode.Repair; continue; }
        if (IsAny(arg, "verify", "/verify", "--verify")) { runMode = RunMode.Verify; continue; }
        if (IsAny(arg, "debug", "/debug", "--debug")) { debug = true; continue; }
        if (IsAny(arg, "no-prompt", "/no-prompt", "--no-prompt")) { promptPaths = false; continue; }
        if (IsAny(arg, "prompt", "/prompt", "--prompt")) { promptPaths = true; continue; }

        if (IsAny(arg, "global", "/global", "--global")) { expectGlobalValue = true; continue; }
        if (IsAny(arg, "scan", "/scan", "--scan", "root", "/root", "--root")) { expectScanValue = true; continue; }
        if (IsAny(arg, "mode", "/mode", "--mode")) { expectModeValue = true; continue; }

        if (TrySplitAssignment(arg, "global", out var globalValue)) { global = TrimWrappedQuotes(globalValue); continue; }
        if (TrySplitAssignment(arg, "scan", out var scanValue)) { scanRoot = TrimWrappedQuotes(scanValue); scanRootProvided = true; continue; }
        if (TrySplitAssignment(arg, "root", out var rootValue)) { scanRoot = TrimWrappedQuotes(rootValue); scanRootProvided = true; continue; }
        if (TrySplitAssignment(arg, "mode", out var modeValue))
        {
            var parsedMode = ParseLinkMode(modeValue);
            if (parsedMode is null) return ParseResult.Fail($"Unsupported mode value '{modeValue}'. Use mode=auto|hardlink|symlink");
            linkMode = parsedMode.Value;
            continue;
        }
        if (TrySplitAssignment(arg, "debug", out var debugValue))
        {
            if (TryParseBoolean(debugValue, out var parsedDebug))
            {
                debug = parsedDebug;
                continue;
            }

            return ParseResult.Fail($"Unsupported debug value '{debugValue}'. Use debug=true|false");
        }
        if (TrySplitAssignment(arg, "prompt", out var promptValue))
        {
            if (TryParseBoolean(promptValue, out var parsedPrompt))
            {
                promptPaths = parsedPrompt;
                continue;
            }

            return ParseResult.Fail($"Unsupported prompt value '{promptValue}'. Use prompt=true|false");
        }

        if (TrySplitInlinePair(arg, "global", out var inlineGlobal)) { global = TrimWrappedQuotes(inlineGlobal); continue; }
        if (TrySplitInlinePair(arg, "scan", out var inlineScan)) { scanRoot = TrimWrappedQuotes(inlineScan); scanRootProvided = true; continue; }
        if (TrySplitInlinePair(arg, "root", out var inlineRoot)) { scanRoot = TrimWrappedQuotes(inlineRoot); scanRootProvided = true; continue; }
        if (TrySplitInlinePair(arg, "mode", out var inlineMode))
        {
            var parsedMode = ParseLinkMode(inlineMode);
            if (parsedMode is null) return ParseResult.Fail($"Unsupported mode value '{inlineMode}'. Use mode=auto|hardlink|symlink");
            linkMode = parsedMode.Value;
            continue;
        }

        return ParseResult.Fail($"Unknown argument '{arg}'");
    }

    if (expectGlobalValue) return ParseResult.Fail("Expected value after global");
    if (expectScanValue) return ParseResult.Fail("Expected value after scan/root");
    if (expectModeValue) return ParseResult.Fail("Expected value after mode");

    return ParseResult.Success(new Options(runMode, scanRoot, global, linkMode, debug, promptPaths, scanRootProvided));
}

static (string Root, string GlobalPath) PromptForPaths(string defaultRoot, string defaultGlobalPath)
{
    Console.WriteLine("Startup configuration:");
    Console.WriteLine("Press ENTER to keep the shown default.");
    Console.Write($"Scan root [{defaultRoot}]: ");
    var rootInput = (Console.ReadLine() ?? string.Empty).Trim();
    var rootValue = rootInput.Length == 0 ? defaultRoot : rootInput;
    var selectedRoot = NormalizePathNoTrailingSlash(Path.GetFullPath(Path.IsPathRooted(rootValue) ? rootValue : Path.Combine(defaultRoot, rootValue)));

    Console.Write($"Global folder [{defaultGlobalPath}]: ");
    var globalInput = (Console.ReadLine() ?? string.Empty).Trim();
    var globalValue = globalInput.Length == 0 ? defaultGlobalPath : globalInput;
    var selectedGlobal = NormalizePathNoTrailingSlash(Path.GetFullPath(Path.IsPathRooted(globalValue) ? globalValue : Path.Combine(selectedRoot, globalValue)));

    Console.WriteLine();
    return (selectedRoot, selectedGlobal);
}

static bool TryParseBoolean(string value, out bool result)
{
    if (value.Equals("1", StringComparison.OrdinalIgnoreCase)
        || value.Equals("true", StringComparison.OrdinalIgnoreCase)
        || value.Equals("yes", StringComparison.OrdinalIgnoreCase)
        || value.Equals("on", StringComparison.OrdinalIgnoreCase))
    {
        result = true;
        return true;
    }

    if (value.Equals("0", StringComparison.OrdinalIgnoreCase)
        || value.Equals("false", StringComparison.OrdinalIgnoreCase)
        || value.Equals("no", StringComparison.OrdinalIgnoreCase)
        || value.Equals("off", StringComparison.OrdinalIgnoreCase))
    {
        result = false;
        return true;
    }

    result = false;
    return false;
}

static string TrimWrappedQuotes(string value)
{
    if (value.Length >= 2 && value[0] == '"' && value[^1] == '"') return value[1..^1];
    return value;
}

static bool IsAny(string value, params string[] choices)
{
    foreach (var choice in choices)
    {
        if (string.Equals(value, choice, StringComparison.OrdinalIgnoreCase)) return true;
    }
    return false;
}

static bool TrySplitAssignment(string value, string key, out string parsed)
{
    foreach (var prefix in new[] { $"{key}=", $"/{key}=", $"--{key}=" })
    {
        if (value.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            parsed = value[prefix.Length..].Trim();
            return true;
        }
    }

    parsed = string.Empty;
    return false;
}

static bool TrySplitInlinePair(string value, string key, out string parsed)
{
    foreach (var prefix in new[] { key + " ", "/" + key + " ", "--" + key + " " })
    {
        if (value.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            parsed = value[prefix.Length..].Trim();
            return parsed.Length > 0;
        }
    }

    parsed = string.Empty;
    return false;
}

static LinkMode? ParseLinkMode(string value)
{
    if (string.Equals(value, "auto", StringComparison.OrdinalIgnoreCase)) return LinkMode.Auto;
    if (string.Equals(value, "hardlink", StringComparison.OrdinalIgnoreCase)) return LinkMode.Hardlink;
    if (string.Equals(value, "symlink", StringComparison.OrdinalIgnoreCase)) return LinkMode.Symlink;
    return null;
}

static void PrintUsage()
{
    Console.WriteLine();
    Console.WriteLine("Usage:");
    Console.WriteLine("  dotnet run --project csharp -- [verify|repair] [scan=PATH|root=PATH | scan PATH] [global=PATH | global PATH] [mode=auto|hardlink|symlink | mode VALUE] [debug|debug=true|debug=false] [no-prompt|prompt=true|prompt=false]");
    Console.WriteLine();
    Console.WriteLine("Examples:");
    Console.WriteLine("  dotnet run --project csharp --");
    Console.WriteLine("  dotnet run --project csharp -- --help");
    Console.WriteLine("  dotnet run --project csharp -- scan \"D:\\AI Libraries\"");
    Console.WriteLine("  dotnet run --project csharp -- global=_MODELS_");
    Console.WriteLine("  dotnet run --project csharp -- global \"D:\\AI Models\\_MODELS_\"");
    Console.WriteLine("  dotnet run --project csharp -- no-prompt scan=\"D:\\AI Libraries\" global=\"D:\\AI\\_global_models\"");
    Console.WriteLine("  dotnet run --project csharp -- /global=D:\\AI\\_global_models /mode=auto");
    Console.WriteLine("  dotnet run --project csharp -- mode=hardlink");
    Console.WriteLine("  dotnet run --project csharp -- debug");
    Console.WriteLine("  dotnet run --project csharp -- no-prompt");
    Console.WriteLine("  dotnet run --project csharp -- verify \"global=D:\\AI\\_global_models\"");
    Console.WriteLine();
    Console.WriteLine("Notes:");
    Console.WriteLine("  mode=auto chooses hardlink on same NTFS volume, otherwise symlink.");
    Console.WriteLine("  Normal mode always asks for explicit E confirmation before modifying files.");
    Console.WriteLine("  Normal mode prompts for scan/global paths by default; press ENTER to keep defaults.");
    Console.WriteLine("  For automation, use no-prompt together with scan/global parameters.");
}

[DllImport("Kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
static extern bool CreateHardLink(string lpFileName, string lpExistingFileName, IntPtr lpSecurityAttributes);

[DllImport("kernel32.dll", SetLastError = true)]
static extern bool GetFileInformationByHandle(SafeFileHandle hFile, out BY_HANDLE_FILE_INFORMATION lpFileInformation);

[StructLayout(LayoutKind.Sequential)]
struct BY_HANDLE_FILE_INFORMATION
{
    public uint FileAttributes;
    public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
    public uint VolumeSerialNumber;
    public uint FileSizeHigh;
    public uint FileSizeLow;
    public uint NumberOfLinks;
    public uint FileIndexHigh;
    public uint FileIndexLow;
}

record ParseResult(bool Ok, string Error, Options? Options)
{
    public static ParseResult Success(Options options) => new(true, string.Empty, options);
    public static ParseResult Fail(string error) => new(false, error, null);
}

record Options(RunMode RunMode, string ScanRoot, string GlobalPath, LinkMode LinkMode, bool Debug, bool PromptPaths, bool ScanRootProvided);
record Candidate(string Category, string ModelName, string FileName, long Size, string SourcePath);
record Operation(string SourcePath, string DestinationPath);
record ScanResult(List<Candidate> Candidates, List<string> AllFilesChecked, int SkippedGlobal, int SkippedAlready, int SkippedIgnored, int SkippedReparse, int ScannedMatches);
record OperationPrep(List<Operation> Operations, int UniqueGroups, int DuplicateCandidates, int HashNeeded);
record ExecutionResult(int Processed, int Moved, int Reused, int Linked, int Hardlinked, int Symlinked, int Restored, int Errors);
record CleanupResult(int Scanned, int Fixed, int Reused, int Pruned, int Errors);
record ProcessResult(int ExitCode, string Output);

enum RunMode
{
    Normal,
    Verify,
    Repair,
    Help
}

enum LinkMode
{
    Auto,
    Hardlink,
    Symlink
}
