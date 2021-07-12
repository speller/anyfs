library anyfs;

{$mode objfpc}{$H+}

uses
  SysUtils,
  fpjson,
  jsonparser,
  Windows,
  Process,
  Classes,
  DateUtils,
  base64,
  fsplugin;

var
  tcIniFile: string;
  pluginIniFile: string;
  rootName: string = 'AnyFS';
  ProgressProc: TProgressProcW;
  LogProc: TLogProcW;
  RequestProc: TRequestProcW;
  TCPluginNr: Integer;


type
  TDirectory = class
  public
    fName: string;
    fTime: TDateTime;
  end;

  TFile = class
  public
    fName: string;
    fTime: TDateTime;
    fSize: Int64;
    fIsLink: Boolean;
  end;

  PDirectoryContents = ^TDirectoryContents;
  TDirectoryContents = record
    currentIndex: Integer;
    dirs: array of TDirectory;
    files: array of TFile;
  end;

  TRawByteStringArray = array of RawByteString;


function FileTime64ToDateTime(AFileTime: FILETIME): TDateTime;
var
  li: ULARGE_INTEGER;
const
  OA_ZERO_TICKS = UInt64(94353120000000000);
  TICKS_PER_DAY = UInt64(864000000000);
begin
  // Convert a FILETIME (which is UTC by definition), into a UTC TDateTime.
  // Copy FILETIME into LARGE_INTEGER to allow UInt64 access without alignment faults.
  li.LowPart := AFileTime.dwLowDateTime;
  li.HighPart := AFileTime.dwHighDateTime;
  Result := (Real(li.QuadPart) - OA_ZERO_TICKS) / TICKS_PER_DAY;
end;

function DateTimeToFileTime64(ADateTimeUTC: TDateTime): FILETIME;
var
    li: ULARGE_INTEGER;
const
    OA_ZERO_TICKS = UInt64(94353120000000000);
    TICKS_PER_DAY = UInt64(864000000000);
begin
    // Convert a UTC TDateTime into a FILETIME (which is UTC by definition).
    li.QuadPart := Round(ADateTimeUtc*TICKS_PER_DAY + OA_ZERO_TICKS);
    Result.dwLowDateTime := li.LowPart;
    Result.dwHighDateTime := li.HighPart;
end;

function GetModuleName: string;
var
  szFileName: array[0..MAX_PATH] of WideChar;
begin
  FillChar(szFileName, SizeOf(szFileName), #0);
  GetModuleFileNameW(hInstance, szFileName, MAX_PATH);
  Result := string(WideString(szFileName));
end;

function isPathAbsolute(const path: string): Boolean;
begin
  Result := (Length(path) > 1) and (path[1] = DirectorySeparator) or (Length(path) > 2) and (path[2] = ':');
end;

function GetPluginIniFileName: string;
var
  dllDir: string;
begin
  if pluginIniFile = '' then
  begin
    pluginIniFile := ChangeFileExt(GetModuleName, '.ini');
  end;
  Result := pluginIniFile;
end;

function GetTCIniFileName: string;
begin
  if tcIniFile = '' then
    tcIniFile := GetPluginIniFileName;
  Result := tcIniFile;
end;

function AddSlash(const s: string): string;
begin
  Result := s;
  if (Length(Result) > 0) and (Result[Length(Result)] = '\') then
    Result := Result + '\';
end;

function GetAddonExe(const addon: string): string;
begin
  SetLength(Result, 1100);
  SetLength(Result, GetPrivateProfileStringA(PChar(addon), 'Interpreter', 'node.exe', @Result[1], Length(Result), PChar(GetPluginIniFileName)));
  if not isPathAbsolute(Result) then
    Result := ExtractFilePath(GetModuleName) + Result;
end;

function GetAddonAddSlash(const addon: string): Boolean;
begin
  Result := GetPrivateProfileIntA(PChar(addon), 'AddTrailingSlash', 1, PChar(GetPluginIniFileName)) > 0;
end;

function ExecuteScript(const addon, scriptDir: string; args: TRawByteStringArray): string;
var
  dir, curDir: TProcessString;
  i: Integer;
begin
  curDir := ExtractFileDir(GetModuleName);
  if isPathAbsolute(scriptDir) then
    dir := scriptDir
  else
    dir := curDir + DirectorySeparator + scriptDir;
  Insert('index.js', args, 0);
  if GetAddonAddSlash(addon) then
    for i := 0 to Length(args) - 1 do
      args[i] := AddSlash(args[i]);

  if not RunCommandInDir(
    dir,
    GetAddonExe(addon),
    args,
    Result,
    [poNoConsole],
    swoNone
  ) then
    raise Exception.Create('Failed running script');
end;

function GetJsonArrayFromOutput(const output: string): TJSONData;
var
  tmp: string;
begin
  try
    Result := GetJSON(output, true);
  except
    tmp := '[' + StringReplace(output, #13, ',', [rfReplaceAll]) + ']';
    Result := GetJSON(tmp, true);
  end;
end;


function ProcessContentsEntry(var contents: TDirectoryContents; var aFindDataW: tWIN32FINDDATAW): Boolean;
var
  dirlen, filelen, i: Integer;
  fil: TFile;
  dir: TDirectory;
  name: WideString;
begin
  FillChar(aFindDataW, SizeOf(aFindDataW), 0);
  i := contents.currentIndex;
  dirlen := Length(contents.dirs);
  filelen := Length(contents.files);
  if i < dirlen then
  begin
    dir := contents.dirs[i];
    name := WideString(Copy(dir.fName, 1, Min(Length(dir.fName), MAX_PATH - 1)));
    Move(name[1], aFindDataW.cFileName, Length(name) * SizeOf(name[1]));
    aFindDataW.dwFileAttributes := FILE_ATTRIBUTE_DIRECTORY;
    aFindDataW.ftLastWriteTime := DateTimeToFileTime64(dir.fTime);
    Inc(contents.currentIndex);
    Result := true;
  end
  else
  begin
    i := i - dirlen;
    if i < filelen then
    begin
      fil := contents.files[i];
      name := WideString(Copy(fil.fName, 1, Min(Length(fil.fName), MAX_PATH - 1)));
      Move(name[1], aFindDataW.cFileName, Length(name) * SizeOf(name[1]));
      aFindDataW.dwFileAttributes := FILE_ATTRIBUTE_NORMAL;
      if fil.fIsLink then
        aFindDataW.dwFileAttributes := FILE_ATTRIBUTE_REPARSE_POINT;
      aFindDataW.ftLastWriteTime := DateTimeToFileTime64(fil.fTime);
      aFindDataW.nFileSizeHigh := Int64Rec(fil.fSize).Hi;
      aFindDataW.nFileSizeLow := Int64Rec(fil.fSize).Lo;
      Inc(contents.currentIndex);
      Result := true;
    end
    else
      Result := false;
  end;
end;

procedure FreeContents(contents: PDirectoryContents);
var
  i: Integer;
begin
  for i := 0 to Length(contents^.dirs) - 1 do
  begin
    contents^.dirs[i].Free;
  end;
  for i := 0 to Length(contents^.files) - 1 do
  begin
    contents^.files[i].Free;
  end;
  SetLength(contents^.files, 0);
  SetLength(contents^.dirs, 0);
  Freemem(contents);
end;

function GetAddonPath(const path: string; var addon: string; var addonDir: string): string;
var
  list: TStringList;
begin
  // Adjust path for addon
  list := TStringList.Create;
  try
    list.LineBreak := '\';
    list.Text := path;
    addon := list.Strings[1];
    list.Delete(1); // Remove the addon name from the path
    list.SkipLastLineBreak := (Length(path) > 0) and (path[Length(path)] <> '\');
    Result := list.Text;
  finally
    list.Free;
  end;

  // Read addon directory
  SetLength(addonDir, 1000);
  SetLength(addonDir, GetPrivateProfileStringA('Addons', PChar(addon), PChar(addon), @addonDir[1], Length(addonDir), PChar(GetPluginIniFileName)));
end;


// ================= TC functions =========================


procedure FsSetDefaultParams(const dps: TFsDefaultParamStruct); stdcall;
begin
  tcIniFile := string(AnsiString(dps.DefaultIniName));
end;

procedure FsGetDefRootName(aDefRootName: PAnsiChar; aMaxLen: Integer); stdcall;
var
  s: AnsiString;
begin
  s := AnsiString(rootName);
  Move(s[1], aDefRootName^, Length(s));
end;

function FsInitW(PluginNr: Integer; pProgressProcW: tProgressProcW; pLogProcW: tLogProcW; pRequestProcW: tRequestProcW): Integer; stdcall;
var
  s: string;
begin
  ProgressProc := pProgressProcW;
  LogProc := pLogProcW;
  RequestProc := pRequestProcW;
  TCPluginNr := PluginNr;
  Result := 0;
end;

function FsFindFirstW(aPath: PWideChar; var FindData: tWIN32FINDDATAW): PDirectoryContents; stdcall;
var
  path, output, addon, buf, scriptDir: string;
  i, itemsCount, dirsCount: Integer;
  jOutput: TJSONData;
  jData: TJSONArray;
  dir: TDirectory;
  fil: TFile;
  jItem: TJSONObject;
  time: Int64;
  list: TStringList;
begin
  FillChar(FindData, SizeOf(FindData), 0);
  path := string(WideString(aPath));
  if path = '\' then
  begin
    // Enumerate available addons in root
    SetLength(buf, 10000);
    SetLength(buf, GetPrivateProfileSectionA('Addons', @buf[1], Length(buf), PChar(GetPluginIniFileName)));
    list := TStringList.Create;
    try
      list.Text := buf;
      if list.Count > 0 then
      begin
        Result := GetMem(SizeOf(Result^));
        FillChar(Result^, SizeOf(Result^), 0);
        SetLength(Result^.dirs, list.Count);
        for i := 0 to list.Count - 1 do
        begin
          dir := TDirectory.Create;
          dir.fName := list.Values[list.Names[i]];
          Result^.dirs[i] := dir;
        end;
        ProcessContentsEntry(Result^, FindData);
      end
      else
      begin
        SetLastError(ERROR_NO_MORE_FILES);
        Result := Pointer(INVALID_HANDLE_VALUE);
      end;
    finally
      list.Free;
    end;
    exit;
  end;

  try
    path := GetAddonPath(path, addon, scriptDir);
  except
    SetLastError(ERROR_BAD_DEVICE);
    Result := Pointer(INVALID_HANDLE_VALUE);
    exit;
  end;
  //MessageBox(0, PChar(output), 'output', 0);

  // Execute addon
  try
    output := ExecuteScript(addon, scriptDir, ['ReadDirectory', path]);
  except
    SetLastError(ERROR_BAD_DEVICE);
    Result := Pointer(INVALID_HANDLE_VALUE);
    exit;
  end;
  //MessageBox(0, PChar(output), 'output', 0);
  if output <> '' then
  begin
    try
      jOutput := GetJsonArrayFromOutput(output);
      if jOutput is TJSONArray then
      begin
        jData := TJSONArray(jOutput);
        if jData.Count > 0 then
        begin
          itemsCount := 0;
          dirsCount := 0;
          for i := 0 to jData.Count - 1 do
            if jData[i] is TJSONObject then
            begin
              Inc(itemsCount);
              if TJSONObject(jData[i]).Get('isDir', false) then
                Inc(dirsCount);
            end;
          if itemsCount > 0 then
          begin
            Result := GetMem(SizeOf(Result^));
            FillChar(Result^, SizeOf(Result^), #0);
            try
              SetLength(Result^.dirs, dirsCount);
              SetLength(Result^.files, itemsCount - dirsCount);
              for i := 0 to jData.Count - 1 do
                if jData[i] is TJSONObject then
                begin
                  jItem := TJSONObject(jData[i]);
                  if jItem.Get('isDir', false) then
                  begin
                    dir := TDirectory.Create;
                    dir.fName := jItem.Get('name');
                    time := jItem.Get('time', Int64(0));
                    if time > 0 then
                      dir.fTime := UnixToDateTime(time, false);
                    Result^.dirs[i] := dir;
                  end
                  else
                  begin
                    fil := TFile.Create;
                    fil.fName := jItem.Get('name');
                    fil.fSize := jItem.Get('size', Int64(0));
                    time := jItem.Get('time', Int64(0));
                    if time > 0 then
                      fil.fTime := UnixToDateTime(time, false);
                    fil.fIsLink := jItem.Get('isLink', false);
                    Result^.files[i - dirsCount] := fil;
                  end;
                end;
              ProcessContentsEntry(Result^, FindData);
              exit;
            except
              FreeContents(Result);
              SetLastError(ERROR_BAD_DEVICE);
              Result := Pointer(INVALID_HANDLE_VALUE);
              exit;
            end;
          end;
        end;
      end;
    except
      SetLastError(ERROR_BAD_DEVICE);
      Result := Pointer(INVALID_HANDLE_VALUE);
      exit;
    end;
  end;
  SetLastError(ERROR_NO_MORE_FILES);
  Result := Pointer(INVALID_HANDLE_VALUE);
end;

function FsFindNextW(contents: PDirectoryContents; var aFindDataW: tWIN32FINDDATAW): BOOL; stdcall;
begin
  Result := ProcessContentsEntry(contents^, aFindDataW);
end;

function FsFindClose(contents: PDirectoryContents): Integer; stdcall;
begin
  FreeContents(contents);
  Result := 0;
end;

function FsGetFileW(aRemoteName, aLocalName: PWideChar; aCopyFlags: Integer; aRemoteInfo: PRemoteInfo): Integer; stdcall;
var
  output, flags, jErr, scriptDir, addon: string;
  jOutput: TJSONData;
  jObj: TJSONObject;
  data: RawByteString;
  remoteName, localName: WideString;
  f: THandle;
begin
  ProgressProc(TCPluginNr, aRemoteName, aLocalName, 0);
  try
    remoteName := aRemoteName;
    localName := aLocalName;
    remoteName := GetAddonPath(remoteName, addon, scriptDir);

    flags := '';
    if aCopyFlags and not FS_COPYFLAGS_OVERWRITE = FS_COPYFLAGS_OVERWRITE then
      flags := flags + 'overwrite,';
    if aCopyFlags and not FS_COPYFLAGS_MOVE = FS_COPYFLAGS_MOVE then
      flags := 'move,';
    if Length(flags) > 0 then
      Delete(flags, Length(flags), 1);

    try
      output := ExecuteScript(addon, scriptDir, ['GetFile', string(remoteName), string(localName), flags]);
    except
      Result := FS_FILE_READERROR;
      exit;
    end;
    //MessageBox(0, PChar(output), 'output', 0);
    if output <> '' then
    begin
      try
        jOutput := GetJsonArrayFromOutput(output);
        if jOutput is TJSONObject then
        begin
          jObj := TJSONObject(jOutput);
          if jObj.Get('success', false) then
          begin
            if jObj.Get('asData', false) then
            begin
              data := jObj.Get('data', '');
              if data <> '' then
                data := DecodeStringBase64(data);
              f := FileOpen(string(localName), fmOpenWrite or fmShareDenyWrite);
              try
                FileWrite(f, data[1], Length(data));
              finally
                FileClose(f);
              end;
            end
            else
            begin
              // Assume file has been copied file by the script
            end;
            Result := FS_FILE_OK;
            exit;
          end
          else
          begin
            jErr := jObj.Get('error', '');
            Result := FS_FILE_READERROR;
            case jErr of
              'exists': Result := FS_FILE_EXISTS;
              'not-found': Result := FS_FILE_NOTFOUND;
              'read-error': Result := FS_FILE_READERROR;
              'write-error' : Result := FS_FILE_WRITEERROR;
            end;
          end;
          exit;
        end;
      except
      end;
    end;
    Result := FS_FILE_READERROR;
  finally
    ProgressProc(TCPluginNr, aRemoteName, aLocalName, 100);
  end;
end;

//function FsPutFileW(LocalName, RemoteName: PWideChar; CopyFlags: Integer): Integer; stdcall;
//begin
//end;

exports
  FsSetDefaultParams,
  FsGetDefRootName,
  FsInitW,
  FsFindFirstW,
  FsFindNextW,
  FsFindClose,
  FsGetFileW;

{$R *.res}

begin
  //MessageBox(0, PChar('THandle: ' + IntToStr(SizeOf(THandle)) + ' Integer: ' + IntToStr(SizeOf(Integer)) + ' Pointer: ' + IntToStr(SizeOf(Pointer))), 'Sizes', 0);
end.

