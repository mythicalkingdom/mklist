program mklist;
{$mode objfpc}{$H+}
{ LIST - a cross-platform text-mode file browser modelled on Vernon Buerg's DOS LIST.
  Free Pascal port. }

uses
  SysUtils, Classes, {$IFDEF UNIX} BaseUnix, termio, {$ENDIF} {$IFDEF WINDOWS} Windows, {$ENDIF}
  Video, uOpts, uSpool, uKeys, uApp;

const
  VERSION = '0.1.0';
  USAGE =
    'LIST - text mode file browser (DOS LIST compatible keys)' + LineEnding + LineEnding +
    'usage: mklist [-x] [-m SIZE] [- | file | wildcard | directory]...' + LineEnding +
    '       command | mklist          (reads standard input, like a pager)' + LineEnding + LineEnding +
    '  -x, --hex       start in hex mode' + LineEnding +
    '  -m, --mem SIZE  max bytes of a file kept in memory (K/M/G suffix, default 1M);' + LineEnding +
    '                  larger files are read in windows as you move through them' + LineEnding +
    '  -V, --version   print the version' + LineEnding +
    '  -h, --help      this text' + LineEnding + LineEnding +
    'Other options are ignored, so mklist can be used as $PAGER.' + LineEnding +
    'When output is not a terminal the files (or stdin) are simply copied to it.' + LineEnding +
    'Press F1 inside the program for the key list.';

function IsTerminal(h: THandle): Boolean;
{$IFDEF WINDOWS}
var
  mode: DWORD;
begin
  Result := GetConsoleMode(h, mode);
end;
{$ELSE}
begin
  Result := IsATTY(h) <> 0;
end;
{$ENDIF}

{ Copy a handle (file or stdin) to standard output. }
procedure CopyHandle(h: THandle);
var
  buf: array[0..65535] of Byte;
  n: LongInt;
begin
  repeat
    n := FileRead(h, buf, SizeOf(buf));
    if n <= 0 then Break;
    if FileWrite(StdOutputHandle, buf, n) <> n then Break;
  until False;
end;

{ Behave like `cat` when output is redirected. }
procedure CatMode(items: TStringList);
var
  i: Integer;
  h: THandle;
begin
  for i := 0 to items.Count - 1 do begin
    if items[i] = '-' then CopyHandle(StdInputHandle)
    else begin
      h := FileOpen(items[i], fmOpenRead or fmShareDenyNone);
      if h = THandle(-1) then
        WriteLn(StdErr, 'mklist: cannot open ', items[i])
      else begin
        CopyHandle(h);
        FileClose(h);
      end;
    end;
  end;
end;

var
  items, files: TStringList;
  hex, pathArgs, gotStdin: Boolean;
  mem, n: Int64;
  menuDir, a: string;
  i: Integer;
  spool: TSpool;
  app: TApp;
begin
  hex := False;
  pathArgs := False;
  gotStdin := False;
  mem := 0;
  menuDir := '';
  spool := nil;
  items := TStringList.Create;
  i := 1;
  while i <= ParamCount do begin
    a := ParamStr(i);
    if (a = '-h') or (a = '--help') or (a = '-?') then begin
      WriteLn(USAGE);
      Halt(0);
    end else if (a = '-V') or (a = '--version') then begin
      WriteLn('mklist ', VERSION, ' (Free Pascal)');
      Halt(0);
    end else if (a = '-x') or (a = '--hex') then
      hex := True
    else if (a = '-m') or (a = '--mem') then begin
      Inc(i);
      if (i > ParamCount) or not ParseSize(ParamStr(i), n) then begin
        WriteLn(StdErr, 'mklist: bad or missing size for --mem (try 512K, 1M, 8M)');
        Halt(1);
      end;
      mem := n;
    end else if Copy(a, 1, 6) = '--mem=' then begin
      if not ParseSize(Copy(a, 7, MaxInt), n) then begin
        WriteLn(StdErr, 'mklist: bad size for --mem (try 512K, 1M, 8M)');
        Halt(1);
      end;
      mem := n;
    end else if a = '-' then begin
      pathArgs := True;
      if not gotStdin then begin items.Add('-'); gotStdin := True; end;
    end else if (Length(a) > 1) and (a[1] = '-') then
      { unknown options are ignored so that PAGER=mklist works with tools that pass flags }
    else begin
      pathArgs := True;
      if DirectoryExists(a) and (Pos('*', a) = 0) and (Pos('?', a) = 0) then menuDir := a
      else ExpandSpec(a, items);
    end;
    Inc(i);
  end;
  if (not pathArgs) and (not IsTerminal(StdInputHandle)) then begin
    items.Add('-');
    gotStdin := True;
  end;
  if pathArgs and (items.Count = 0) and (menuDir = '') then begin
    WriteLn(StdErr, 'mklist: no files match');
    Halt(1);
  end;
  if not IsTerminal(StdOutputHandle) then begin
    CatMode(items);
    Halt(0);
  end;

  files := TStringList.Create;
  try
    for i := 0 to items.Count - 1 do begin
      if items[i] = '-' then begin
        if spool = nil then spool := TSpool.Create;
        files.Add(spool.path);
      end else
        files.Add(items[i]);
    end;
  except
    on E: Exception do begin
      WriteLn(StdErr, 'mklist: ', E.Message);
      Halt(1);
    end;
  end;

  try
    app := TApp.Create(files, menuDir, hex, mem, spool);
  except
    on E: Exception do begin
      WriteLn(StdErr, 'mklist: ', E.Message);
      if spool <> nil then spool.Cleanup;
      Halt(1);
    end;
  end;

  InitVideo;
  KeysInit;
  try
    app.Run;
  finally
    KeysDone;
    DoneVideo;
  end;
  app.Finish;
  if app.ExitClear then Write(#27'[2J'#27'[H');
  if spool <> nil then spool.Cleanup;
end.
