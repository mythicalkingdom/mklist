unit uApp;
{$mode objfpc}{$H+}
{ Application state: key handling (DOS LIST compatible), the command line, popups and drawing. }

interface

uses SysUtils, Classes, RegExpr, Video, {$IFDEF UNIX} BaseUnix, Unix, termio, {$ENDIF}
     uOpts, uCP437, uScreen, uViewer, uSpool, uKeys;

type
  TMode = (mNormal, mInput, mHelp, mMenu, mToggles);
  TQuit = (qNone, qClear, qRestore);
  TEntry = record
    name: string;
    dir: Boolean;
    size: Int64;
  end;

  TApp = class
  public
    opts: TOpts;
    constructor Create(AFiles: TStringList; const AMenuDir: string; AHex: Boolean; AMem: Int64;
                       ASpool: TSpool);
    procedure Run;
    procedure Finish;
    function ExitClear: Boolean;
  private
    wins: array of TViewer;
    active: Integer;
    files: TStringList;
    spool: TSpool;
    forceHex: Boolean;
    mode: TMode;
    helpPage: Integer;
    msg: string;
    hasFind: Boolean;
    find: TFind;
    input: string;
    cursor: Integer;        { byte index, 0-based }
    quit: TQuit;
    shellReq: Boolean;
    positions, history: TStringList;
    histPos: Integer;
    draft: string;
    menuDir: string;
    menuEntries: array of TEntry;
    menuSel, menuScroll: Integer;
    lastInput: QWord;
    blank: Boolean;

    procedure CheckResize;
    function WaitInput(out k: TKey): Boolean;
    procedure Draw;
    procedure DrawHelp;
    procedure DrawMenu;
    procedure DrawToggles;
    procedure Boxed(x, y, w, h: Integer; const title: string);
    procedure OnKey(const k: TKey);
    procedure NormalKey(const k: TKey);
    procedure InputKey(const k: TKey);
    procedure MenuKey(const k: TKey);
    procedure FKey(n: Integer);
    procedure PlainKey(c: Char);
    procedure AltKey(c: Char);
    procedure StartInput(const prefill: string);
    procedure SetInput(const s: string);
    procedure HistMove(up: Boolean);
    procedure Exec(const s: string);
    procedure NewFind(const text: string; ci: Boolean);
    procedure NewRegex(const pat: string; ci: Boolean);
    procedure SetFind(const f: TFind);
    procedure NewBytes(const arg: string);
    procedure DoFind(fwd: Boolean);
    procedure ToggleFollow;
    procedure GotoStr(const s: string);
    procedure CmdOpen(const spec: string; insert: Boolean);
    procedure CmdWrite(const name: string; append: Boolean);
    procedure CmdMem(const arg: string);
    procedure PrintMarked;
    procedure MenuLoad(const dir: string);
    procedure OpenMenu;
    procedure QuitNext;
    procedure OpenInActive(idx: Integer);
    function OpenViewer(idx: Integer): TViewer;
    procedure RememberPos(w: Integer);
    procedure RunShell;
    procedure Tick(var changed: Boolean);
  end;

function ExpandSpec(const spec: string; files: TStringList): Integer;

implementation

const
  KEYS_HINT = 'Keys: ↑↓→← PgUp PgDn F10=exit F1=Help';

  HELP2: array[0..22] of string = (
    '',
    '                  NAVIGATION AND COMMAND LINE',
    '',
    '  Up/Down/PgUp/PgDn  scroll             Home/End  top / bottom of file',
    '  Left/Right         scroll sideways    Space     page down',
    '  Enter or :         open command line  Esc       quit to next file',
    '  Up/Down (on the command line)  recall earlier commands and searches',
    '  / \ + - # $ r      open it pre-filled for a find, skip or regex search',
    '',
    '  Commands (type on the Command line, then Enter):',
    '    goto N | #N | +N | -N    skip to a line (in hex mode, a row)',
    '    $HEX                     skip to a hex byte offset',
    '    find TEXT | exact TEXT   search any case / exact; next | prev repeat it',
    '    re PATTERN | rex PAT     regex search, any case / exact (per line, byte-wise)',
    '    bytes 41 42 0D 0A        search for hex bytes',
    '    follow | remember        tail the file / remember the last position',
    '    hex | text | wrap | tabs | ruler | junk | hibit 7|8|*',
    '    open SPEC | insert SPEC | files | nextfile | firstfile',
    '    copy FILE | append FILE | print | mark top|bottom|clear | recall',
    '    windows | save | toggles | dos | help | quit | exit',
    '    mem SIZE                 max memory per file (512K, 1M, 8M ...); bigger',
    '                             files are read in windows around your position',
    '  Alt-W splits the screen into two windows; Alt-W switches, Q closes one.');

  FKEYS: array[0..16] of string = (
    'F1  Display HELP', 'F2  set FIND bg', 'F3  Find next text', 'F4  set FIND fg',
    'F5  set text bg', 'F6  set text fg', 'F7  set 1/25 bg', 'F8  set 1/25 fg',
    'F9  Find prev text', 'F10 Exit to DOS', '\   Scan for exact text', '/   Find any case text',
    '', 'P   Printer on/off', 'W   Wrap long lines', 'Q   quit to next file', 'X   Exit to DOS, cls');
  ALT1: array[0..16] of string = (
    'a-A  find text Again', 'a-B  mark Bottom line', 'a-C  Save options', 'a-D  copy to file',
    'a-E  toggle EGA 25/43', 'a-F  get new Filespec', 'a-G  Goto DOS', 'a-H  toggle Hex mode',
    'a-I  insert new file', 'a-J  Junk filter', 'a-K  toggle Key ahead', 'a-L  toggle preLoading',
    'a-M  Mark top line', 'a-N  screen saving', 'a-O  append data', 'a-P  print marked',
    'a-R  Ruler on/off');
  ALT2: array[0..16] of string = (
    'a-S  Sharing on/off', 'a-T  Tabs on/off', 'a-U  Unmark lines', 'a-V  file select menu',
    'a-W  toggle windows', 'a-X  exit, restore screen', 'a-Y  recall bookmark', 'a-Z  show toggles',
    '', '7/8/*  hi-bit filters', '+/-/#  skip to line #', '$      skip to hex offset',
    '1      display first file', '', 'f      follow (tail) on/off', 'r      regex search',
    'Enter  command line');

{ ---------------------------------------------------------------- small helpers }

function PadR(const s: string; n: Integer): string;
var
  k: Integer;
begin
  k := Utf8Len(s);
  if k >= n then Result := s else Result := s + StringOfChar(' ', n - k);
end;

function LC(c: Char): Char;
begin
  if (c >= 'A') and (c <= 'Z') then Result := Chr(Ord(c) + 32) else Result := c;
end;

function OnOff(b: Boolean): string;
begin
  if b then Result := 'ON ' else Result := 'off';
end;

procedure Cycle(var c: Byte; other: Byte; modulus: Integer);
begin
  c := (c + 1) mod modulus;
  if c = other then c := (c + 1) mod modulus;
end;

{ DOS-style wildcard match (* and ?), case-insensitive. }
function Wild(const pat, name: string; pi, ni: Integer): Boolean;
begin
  if pi > Length(pat) then Exit(ni > Length(name));
  if pat[pi] = '*' then begin
    Result := False;
    while ni <= Length(name) + 1 do begin
      if Wild(pat, name, pi + 1, ni) then Exit(True);
      Inc(ni);
    end;
    Exit;
  end;
  if ni > Length(name) then Exit(False);
  if (pat[pi] = '?') or (LowerCase(pat[pi]) = LowerCase(name[ni])) then
    Result := Wild(pat, name, pi + 1, ni + 1)
  else
    Result := False;
end;

procedure SortStrings(sl: TStringList);
begin
  sl.CaseSensitive := False;
  sl.Sort;
end;

{ Expand a file spec (wildcards and directories) into a sorted list of paths; returns the count. }
function ExpandSpec(const spec: string; files: TStringList): Integer;
var
  sr: TSearchRec;
  dir, pat, nm: string;
  tmp: TStringList;
  i: Integer;
begin
  tmp := TStringList.Create;
  try
    if (Pos('*', spec) > 0) or (Pos('?', spec) > 0) or DirectoryExists(spec) then begin
      if DirectoryExists(spec) then begin dir := IncludeTrailingPathDelimiter(spec); pat := '*'; end
      else begin dir := ExtractFilePath(spec); pat := ExtractFileName(spec); end;
      if FindFirst(dir + '*', faAnyFile, sr) = 0 then begin
        repeat
          nm := sr.Name;
          if ((sr.Attr and faDirectory) = 0) and Wild(pat, nm, 1, 1) then tmp.Add(dir + nm);
        until FindNext(sr) <> 0;
        FindClose(sr);
      end;
      SortStrings(tmp);
    end else
      tmp.Add(spec);
    for i := 0 to tmp.Count - 1 do files.Add(tmp[i]);
    Result := tmp.Count;
  finally
    tmp.Free;
  end;
end;

function Utf8PrevStart(const s: string; idx: Integer): Integer;
{ idx is a 1-based byte index; returns the start of the character before it }
begin
  Result := idx - 1;
  while (Result > 1) and ((Byte(s[Result]) and $C0) = $80) do Dec(Result);
end;

function Utf8NextStart(const s: string; idx: Integer): Integer;
begin
  Result := idx + 1;
  while (Result <= Length(s)) and ((Byte(s[Result]) and $C0) = $80) do Inc(Result);
end;

function CpToUtf8(cp: Cardinal): string;
begin
  if cp < $80 then Result := Chr(cp)
  else if cp < $800 then Result := Chr($C0 or (cp shr 6)) + Chr($80 or (cp and $3F))
  else Result := Chr($E0 or (cp shr 12)) + Chr($80 or ((cp shr 6) and $3F)) + Chr($80 or (cp and $3F));
end;

{ ---------------------------------------------------------------- construction }

constructor TApp.Create(AFiles: TStringList; const AMenuDir: string; AHex: Boolean; AMem: Int64;
                        ASpool: TSpool);
var
  d: string;
  sl: TStringList;
begin
  inherited Create;
  OptsDefault(opts);
  OptsLoad(opts);
  if AMem > 0 then opts.maxMem := AMem;
  files := AFiles;
  spool := ASpool;
  forceHex := AHex;
  active := 0;
  mode := mNormal;
  quit := qNone;
  histPos := -1;
  positions := TStringList.Create;
  history := TStringList.Create;
  d := ConfigDir;
  if d <> '' then begin
    d := IncludeTrailingPathDelimiter(d);
    if FileExists(d + 'positions.txt') then try positions.LoadFromFile(d + 'positions.txt'); except end;
    if FileExists(d + 'history.txt') then try history.LoadFromFile(d + 'history.txt'); except end;
  end;
  SetLength(wins, 1);
  wins[0] := TViewer.Create;
  if files.Count > 0 then begin
    wins[0].Free;
    wins[0] := OpenViewer(0);
  end else begin
    if AMenuDir <> '' then MenuLoad(AMenuDir) else MenuLoad(GetCurrentDir);
    mode := mMenu;
  end;
  lastInput := GetTickCount64;
  sl := nil;
end;

function TApp.ExitClear: Boolean;
begin
  Result := quit = qClear;
end;

function PosKey(const p: string): string;
begin
  Result := ExpandFileName(p);
end;

function TApp.OpenViewer(idx: Integer): TViewer;
var
  v: TViewer;
  i, p: Integer;
  key: string;
  off: Int64;
begin
  v := TViewer.Create;
  try
    v.OpenFile(files[idx], opts.maxMem);
  except
    v.Free;
    raise;
  end;
  if (spool <> nil) and (spool.path = files[idx]) then begin
    v.MakeStream('(stdin)');
    Exit(v);
  end;
  if opts.remember then begin
    key := PosKey(v.path);
    for i := positions.Count - 1 downto 0 do begin
      p := Pos(#9, positions[i]);
      if (p > 0) and (Copy(positions[i], p + 1, MaxInt) = key) then begin
        off := StrToInt64Def(Copy(positions[i], 1, p - 1), 0);
        if off > 0 then begin
          if off > v.fileLen - 1 then off := v.fileLen - 1;
          if off < 0 then off := 0;
          v.GotoOff(off, opts);
        end;
        Break;
      end;
    end;
  end;
  if v.LooksBinary and not forceHex then begin
    v.ToggleHex;
    msg := 'Binary file - hex mode (Alt-H for text)';
  end;
  if forceHex and not v.hex then v.ToggleHex;
  Result := v;
end;

{ Note where the user was in window w so the next session can return there. }
procedure TApp.RememberPos(w: Integer);
var
  v: TViewer;
  key: string;
  i, p: Integer;
begin
  v := wins[w];
  if (not opts.remember) or v.isStream or (v.path = '') then Exit;
  key := PosKey(v.path);
  for i := positions.Count - 1 downto 0 do begin
    p := Pos(#9, positions[i]);
    if (p > 0) and (Copy(positions[i], p + 1, MaxInt) = key) then positions.Delete(i);
  end;
  positions.Add(IntToStr(v.CurTopOff) + #9 + key);
  while positions.Count > 300 do positions.Delete(0);
end;

{ Save positions and history; call once when the program is exiting. }
procedure TApp.Finish;
var
  d: string;
  i: Integer;
  h: TStringList;
begin
  for i := 0 to High(wins) do RememberPos(i);
  d := ConfigDir;
  if d = '' then Exit;
  try
    ForceDirectories(d);
    d := IncludeTrailingPathDelimiter(d);
    positions.SaveToFile(d + 'positions.txt');
    h := TStringList.Create;
    try
      for i := History.Count - 200 to History.Count - 1 do
        if i >= 0 then h.Add(history[i]);
      h.SaveToFile(d + 'history.txt');
    finally
      h.Free;
    end;
  except
  end;
end;

{ ---------------------------------------------------------------- input }

procedure TApp.CheckResize;
{$IFDEF UNIX}
var
  ws: TWinSize;
  m: TVideoMode;
begin
  if fpIoctl(StdInputHandle, TIOCGWINSZ, @ws) = 0 then
    if (ws.ws_col > 0) and ((ws.ws_col <> ScreenWidth) or (ws.ws_row <> ScreenHeight)) then begin
      GetVideoMode(m);
      m.Col := ws.ws_col;
      m.Row := ws.ws_row;
      SetVideoMode(m);
      UpdateScreen(True);
    end;
end;
{$ELSE}
begin
end;
{$ENDIF}

procedure TApp.Tick(var changed: Boolean);
var
  i: Integer;
begin
  for i := 0 to High(wins) do
    if wins[i].Refresh(opts) then changed := True;
end;

{ Wait for a key. Returns True with the key, or False when the screen should just be redrawn
  (new data arrived, the terminal was resized, or the screen saver kicked in). }
function TApp.WaitInput(out k: TKey): Boolean;
var
  lastRefresh: QWord;
  pending, changed, grew: Boolean;
  i, interval: Integer;
  sw, sh: Integer;
begin
  Result := False;
  k.kind := kNone;
  lastRefresh := GetTickCount64;
  sw := ScreenWidth; sh := ScreenHeight;
  repeat
    if KeyRead(k) then Exit(True);
    CheckResize;
    if (sw <> ScreenWidth) or (sh <> ScreenHeight) then Exit(False);
    grew := False;
    if (spool <> nil) and not spool.done then begin
      if spool.Pump then grew := True;
      pending := True;
      for i := 0 to High(wins) do
        if wins[i].isStream then wins[i].streamDone := spool.done;
    end else begin
      pending := False;
      for i := 0 to High(wins) do
        if wins[i].isStream and not wins[i].streamDone then begin
          wins[i].streamDone := True;
          grew := True;
        end;
    end;
    if pending then interval := 100 else interval := 500;
    if grew or (GetTickCount64 - lastRefresh >= QWord(interval)) then begin
      lastRefresh := GetTickCount64;
      changed := grew;
      Tick(changed);
      if changed then Exit(False);
    end;
    if opts.saver and not blank and (GetTickCount64 - lastInput > 300000) then begin
      blank := True;
      Exit(False);
    end;
    Sleep(10);
  until False;
end;

procedure TApp.Run;
var
  k: TKey;
  cx, cy, skipped: Integer;
begin
  skipped := 0;
  repeat
    { while more keys are already waiting (a paste, or a held-down key) skip the redraw }
    if (quit = qNone) and KeyPending and (skipped < 60) then
      Inc(skipped)
    else begin
      skipped := 0;
      if blank then ScrClear(0, 0) else Draw;
      ScrFlush;
    end;
    if (mode = mInput) and not blank then begin
      cx := 8 + Utf8Len(Copy(input, 1, cursor));
      if cx >= ScreenWidth then cx := ScreenWidth - 1;
      cy := ScreenHeight - 1;
      SetCursorPos(cx, cy);
      SetCursorType(crUnderline);
    end else
      SetCursorType(crHidden);
    if quit <> qNone then Break;
    if WaitInput(k) then begin
      lastInput := GetTickCount64;
      if blank then begin
        blank := False;
        UpdateScreen(True);
      end else begin
        OnKey(k);
        if not opts.keyAhead then KeysFlush;
      end;
    end;
    if shellReq then begin
      shellReq := False;
      RunShell;
    end;
  until False;
end;

procedure TApp.RunShell;
var
  sh: string;
begin
  KeysDone;
  DoneVideo;
  WriteLn('Type EXIT to return to LIST.');
  {$IFDEF WINDOWS}
  sh := GetEnvironmentVariable('COMSPEC');
  if sh = '' then sh := 'cmd';
  {$ELSE}
  sh := GetEnvironmentVariable('SHELL');
  if sh = '' then sh := '/bin/sh';
  {$ENDIF}
  try
    ExecuteProcess(sh, '');
  except
  end;
  InitVideo;
  KeysInit;
  ClearScreen;
  UpdateScreen(True);
end;

{ ---------------------------------------------------------------- drawing }

procedure TApp.Boxed(x, y, w, h: Integer; const title: string);
var
  r, i: Integer;
  t: string;
  fg, bg: Byte;
begin
  fg := opts.statFg; bg := opts.statBg;
  for r := 0 to h - 1 do ScrFill(x, y + r, w, 32, fg, bg);
  for i := 1 to w - 2 do begin
    ScrPut(x + i, y, $CD, fg, bg);
    ScrPut(x + i, y + h - 1, $CD, fg, bg);
  end;
  for r := 1 to h - 2 do begin
    ScrPut(x, y + r, $BA, fg, bg);
    ScrPut(x + w - 1, y + r, $BA, fg, bg);
  end;
  ScrPut(x, y, $C9, fg, bg);
  ScrPut(x + w - 1, y, $BB, fg, bg);
  ScrPut(x, y + h - 1, $C8, fg, bg);
  ScrPut(x + w - 1, y + h - 1, $BC, fg, bg);
  t := ' ' + title + ' ';
  ScrPutsN(x + 2, y, t, w - 4, fg, bg);
end;

procedure TApp.DrawHelp;
var
  i, fg, row: Integer;
  l: string;
  rows: array of string;
begin
  SetLength(rows, 0);
  if helpPage = 0 then begin
    SetLength(rows, 19);
    rows[0] := '';
    rows[1] := PadR('   FUNCTION KEYS', 26) + PadR('   ALT- KEYS', 26) + '   ALT- KEYS';
    for i := 0 to 16 do
      rows[2 + i] := ' ' + PadR(FKEYS[i], 25) + ' ' + PadR(ALT1[i], 25) + ' ' + ALT2[i];
  end else begin
    SetLength(rows, Length(HELP2));
    for i := 0 to High(HELP2) do rows[i] := HELP2[i];
  end;
  for row := 0 to High(rows) do begin
    if row >= ScreenHeight - 1 then Break;
    l := rows[row];
    if (Pos('KEYS', l) > 0) or (Pos('NAVIGATION', l) > 0) then fg := 14 else fg := opts.textFg;
    ScrPuts(0, row, l, fg, opts.textBg);
  end;
end;

procedure TApp.DrawMenu;
var
  w, h, x, y, r, f, b, namew, i: Integer;
  e: TEntry;
  size: string;
begin
  w := ScreenWidth - 4; if w > 64 then w := 64;
  h := ScreenHeight - 3; if h > 24 then h := 24;
  if (w < 20) or (h < 5) then Exit;
  x := (ScreenWidth - w) div 2;
  y := (ScreenHeight - 1 - h) div 2;
  Boxed(x, y, w, h, 'Select file - ' + menuDir);
  for r := 0 to h - 3 do begin
    i := menuScroll + r;
    if i > High(menuEntries) then Break;
    e := menuEntries[i];
    if i = menuSel then begin f := opts.statBg; b := opts.statFg; end else begin f := opts.statFg; b := opts.statBg; end;
    if e.dir then size := '<DIR>' else size := IntToStr(e.size);
    namew := w - 4 - 12;
    ScrFill(x + 1, y + 1 + r, w - 2, 32, f, b);
    ScrPutsN(x + 2, y + 1 + r, e.name, namew, f, b);
    ScrPuts(x + w - 3 - Length(size), y + 1 + r, size, f, b);
  end;
end;

procedure TApp.DrawToggles;
var
  v: TViewer;
  lines: array of string;
  i, w, h, x, y: Integer;
  hb: string;
begin
  v := wins[active];
  case opts.hibit of
    1: hb := '7 (strip)';
    2: hb := '* (filter)';
  else hb := '8 (all)';
  end;
  SetLength(lines, 14);
  lines[0] := 'Hex mode ........ ' + OnOff(v.hex) + '   (Alt-H)';
  lines[1] := 'Wrap long lines . ' + OnOff(opts.wrap) + '   (W)';
  lines[2] := 'Tabs ............ ' + OnOff(opts.tabs) + '   (Alt-T)';
  lines[3] := 'Ruler ........... ' + OnOff(opts.ruler) + '   (Alt-R)';
  lines[4] := 'Junk filter ..... ' + OnOff(opts.junk) + '   (Alt-J)';
  lines[5] := 'Hi-bit filter ... ' + hb + '   (7/8/*)';
  lines[6] := 'Key ahead ....... ' + OnOff(opts.keyAhead) + '   (Alt-K)';
  lines[7] := 'Preloading ...... ' + OnOff(opts.preload) + '   (Alt-L)';
  lines[8] := 'Screen saving ... ' + OnOff(opts.saver) + '   (Alt-N)';
  lines[9] := 'Sharing ......... ' + OnOff(opts.sharing) + '   (Alt-S)';
  lines[10] := 'Printer ......... ' + OnOff(opts.printer) + '   (P)';
  lines[11] := 'Max memory ..... ' + FmtSize(opts.maxMem) + '   (mem SIZE)';
  lines[12] := 'Follow (tail) ... ' + OnOff(v.follow) + '   (f)';
  lines[13] := 'Remember pos .... ' + OnOff(opts.remember) + '   (remember)';
  w := 50;
  h := Length(lines) + 2;
  if (ScreenWidth < w) or (ScreenHeight < h + 1) then Exit;
  x := (ScreenWidth - w) div 2;
  y := (ScreenHeight - 1 - h) div 2;
  Boxed(x, y, w, h, 'Toggles');
  for i := 0 to High(lines) do ScrPuts(x + 3, y + 1 + i, lines[i], opts.statFg, opts.statBg);
end;

procedure TApp.Draw;
var
  w, h, body, h1, i, y, hintX, room: Integer;
  bottomMsg, text: string;
  hasBottom: Boolean;
  v: TViewer;
  fp: PFind;
begin
  w := ScreenWidth; h := ScreenHeight;
  ScrClear(opts.textFg, opts.textBg);
  if h < 3 then Exit;
  body := h - 1;
  hasBottom := False;
  if hasFind then fp := @find else fp := nil;
  if mode = mHelp then begin
    DrawHelp;
    bottomMsg := '*** Help ' + IntToStr(helpPage + 1) + '/2 - any key ***';
    hasBottom := True;
  end else begin
    if Length(wins) = 1 then
      wins[0].Render(0, body, w, opts, fp, True)
    else begin
      h1 := body div 2;
      for i := 0 to High(wins) do
        if i = 0 then wins[i].Render(0, h1, w, opts, fp, i = active)
        else wins[i].Render(h1, body - h1, w, opts, fp, i = active);
    end;
  end;
  if mode = mMenu then DrawMenu;
  if mode = mToggles then DrawToggles;
  { bottom command line }
  y := h - 1;
  ScrFill(0, y, w, 32, opts.statFg, opts.statBg);
  ScrPuts(0, y, 'Command►', opts.statFg, opts.statBg);
  hintX := w - Utf8Len(KEYS_HINT);
  if mode = mInput then
    ScrPutsN(8, y, input, w - 9, opts.statFg, opts.statBg)
  else begin
    v := wins[active];
    if hasBottom then text := bottomMsg
    else if msg <> '' then text := msg
    else if v.follow then text := '*** Following - f to stop ***'
    else if v.atEof and (mode <> mMenu) then begin
      if v.InputPending then text := '*** Waiting for input ***' else text := '*** End-of-file ***';
    end else text := '';
    if hintX >= 28 then room := hintX - 13 else room := w - 13;
    ScrPutsN(13, y, text, room, opts.statFg, opts.statBg);
    if hintX >= 28 then ScrPuts(hintX, y, KEYS_HINT, opts.statFg, opts.statBg);
  end;
end;

{ ---------------------------------------------------------------- key handling }

procedure TApp.OnKey(const k: TKey);
begin
  case mode of
    mHelp: begin
      if (helpPage < 1) and (k.kind <> kEsc) then Inc(helpPage) else mode := mNormal;
    end;
    mToggles: mode := mNormal;
    mMenu: MenuKey(k);
    mInput: InputKey(k);
  else
    NormalKey(k);
  end;
end;

procedure TApp.SetInput(const s: string);
begin
  input := s;
  cursor := Length(s);
end;

procedure TApp.StartInput(const prefill: string);
begin
  SetInput(prefill);
  histPos := -1;
  mode := mInput;
end;

{ Up/Down on the command line: step through history entries that start with what was typed. }
procedure TApp.HistMove(up: Boolean);
var
  i: Integer;
begin
  if histPos < 0 then begin
    if not up then Exit;
    draft := input;
    i := history.Count;
  end else i := histPos;
  repeat
    if up then begin
      if i = 0 then Exit;
      Dec(i);
    end else begin
      Inc(i);
      if i >= history.Count then begin
        histPos := -1;
        SetInput(draft);
        Exit;
      end;
    end;
    if Copy(history[i], 1, Length(draft)) = draft then begin
      histPos := i;
      SetInput(history[i]);
      Exit;
    end;
  until False;
end;

procedure TApp.InputKey(const k: TKey);
var
  s: string;
  p: Integer;
begin
  case k.kind of
    kEsc: mode := mNormal;
    kEnter: begin
      s := input;
      mode := mNormal;
      if (Trim(s) <> '') and ((history.Count = 0) or (history[history.Count - 1] <> s)) then history.Add(s);
      Exec(s);
    end;
    kBack:
      if cursor > 0 then begin
        p := Utf8PrevStart(input, cursor + 1);
        Delete(input, p, cursor - p + 1);
        cursor := p - 1;
      end;
    kDel:
      if cursor < Length(input) then begin
        p := Utf8NextStart(input, cursor + 1);
        Delete(input, cursor + 1, p - cursor - 1);
      end;
    kLeft: if cursor > 0 then cursor := Utf8PrevStart(input, cursor + 1) - 1;
    kRight: if cursor < Length(input) then cursor := Utf8NextStart(input, cursor + 1) - 1;
    kHome: cursor := 0;
    kEnd: cursor := Length(input);
    kUp: HistMove(True);
    kDown: HistMove(False);
    kCtrl: if k.ch = 'u' then begin input := ''; cursor := 0; end;
    kChar: begin
      Insert(k.ch, input, cursor + 1);
      Inc(cursor);
    end;
  end;
end;

procedure TApp.NormalKey(const k: TKey);
var
  v: TViewer;
  page: Integer;
begin
  msg := '';
  v := wins[active];
  page := v.vh;
  if page < 1 then page := 1;
  case k.kind of
    kCtrl: if k.ch = 'c' then quit := qRestore;
    kF: FKey(k.n);
    kAlt: AltKey(k.ch);
    kChar: PlainKey(k.ch);
    kUp: begin v.follow := False; v.Up(1, opts); end;
    kDown: v.Down(1, opts);
    kPgUp: begin v.follow := False; v.Up(page, opts); end;
    kPgDn: v.Down(page, opts);
    kHome: begin v.follow := False; v.GoHome; end;
    kEnd: v.GoEnd(opts);
    kLeft: if not v.hex then begin
      if v.col >= 8 then Dec(v.col, 8) else v.col := 0;
    end;
    kRight: if (not v.hex) and (not opts.wrap) then begin
      Inc(v.col, 8);
      if v.col > v.maxW - 1 then v.col := v.maxW - 1;
      if v.col < 0 then v.col := 0;
    end;
    kEnter: StartInput('');
    kEsc: QuitNext;
  end;
end;

procedure TApp.FKey(n: Integer);
begin
  case n of
    1: begin mode := mHelp; helpPage := 0; end;
    2: Cycle(opts.findBg, opts.findFg, 8);
    3: DoFind(True);
    4: Cycle(opts.findFg, opts.findBg, 16);
    5: Cycle(opts.textBg, opts.textFg, 8);
    6: Cycle(opts.textFg, opts.textBg, 16);
    7: Cycle(opts.statBg, opts.statFg, 8);
    8: Cycle(opts.statFg, opts.statBg, 16);
    9: DoFind(False);
    10: quit := qClear;
  end;
end;

procedure TApp.PlainKey(c: Char);
var
  v: TViewer;
  i: Integer;
begin
  v := wins[active];
  case LC(c) of
    'p': begin
      opts.printer := not opts.printer;
      if opts.printer then msg := 'Printer on' else msg := 'Printer off';
    end;
    'w': begin
      opts.wrap := not opts.wrap;
      for i := 0 to High(wins) do begin wins[i].col := 0; wins[i].sub := 0; end;
    end;
    'q': QuitNext;
    'x': quit := qClear;
    '/', '\', '+', '-', '#', '$': StartInput(c);
    ':': StartInput('');
    'f': ToggleFollow;
    'r': StartInput('re ');
    '1': if files.Count = 0 then msg := 'No file list' else OpenInActive(0);
    '7': opts.hibit := 1;
    '8': opts.hibit := 0;
    '*': opts.hibit := 2;
    ' ': v.Down(v.vh, opts);
  end;
end;

procedure TApp.AltKey(c: Char);
var
  v: TViewer;
  nv: TViewer;
  off: Int64;
begin
  v := wins[active];
  case c of
    'a': DoFind(True);
    'b': begin v.markBot := v.botOff; msg := 'Bottom line marked'; end;
    'c': try
           msg := 'Options saved to ' + OptsSave(opts);
         except
           on E: Exception do msg := 'Cannot save options: ' + E.Message;
         end;
    'd': StartInput('copy ');
    'e': msg := 'Changing the number of rows is not supported in this build';
    'f': StartInput('open ');
    'g': shellReq := True;
    'h': v.ToggleHex;
    'i': StartInput('insert ');
    'j': opts.junk := not opts.junk;
    'k': opts.keyAhead := not opts.keyAhead;
    'l': opts.preload := not opts.preload;
    'm': begin
      off := v.CurTopOff;
      v.markTop := off;
      v.bookmark := off;
      msg := 'Top line marked (bookmark set)';
    end;
    'n': begin
      opts.saver := not opts.saver;
      if opts.saver then msg := 'Screen saving on (5 min)' else msg := 'Screen saving off';
    end;
    'o': StartInput('append ');
    'p': PrintMarked;
    'r': opts.ruler := not opts.ruler;
    's': opts.sharing := not opts.sharing;
    't': opts.tabs := not opts.tabs;
    'u': begin v.markTop := -1; v.markBot := -1; end;
    'v': OpenMenu;
    'w': begin
      if Length(wins) = 1 then begin
        nv := TViewer.Create;
        nv.Assign(wins[0]);
        SetLength(wins, 2);
        wins[1] := nv;
        active := 1;
        msg := 'Two windows: Alt-W switches, Q closes one';
      end else active := 1 - active;
    end;
    'x': quit := qRestore;
    'y': if v.bookmark >= 0 then v.GotoOff(v.bookmark, opts)
         else msg := 'No bookmark set (Alt-M marks the top line)';
    'z': mode := mToggles;
  end;
end;

{ ---------------------------------------------------------------- file menu }

procedure TApp.MenuLoad(const dir: string);
var
  sr: TSearchRec;
  e: TEntry;
  n, i, j: Integer;
  tmp: TEntry;
begin
  menuDir := ExpandFileName(dir);
  if (Length(menuDir) > 1) and (menuDir[Length(menuDir)] = PathDelim) then
    SetLength(menuDir, Length(menuDir) - 1);
  SetLength(menuEntries, 0);
  if FindFirst(IncludeTrailingPathDelimiter(menuDir) + '*', faAnyFile, sr) = 0 then begin
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      e.name := sr.Name;
      e.dir := (sr.Attr and faDirectory) <> 0;
      e.size := sr.Size;
      SetLength(menuEntries, Length(menuEntries) + 1);
      menuEntries[High(menuEntries)] := e;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  { directories first, then by name }
  n := Length(menuEntries);
  for i := 1 to n - 1 do begin
    tmp := menuEntries[i];
    j := i - 1;
    while (j >= 0) and ((menuEntries[j].dir < tmp.dir) or
          ((menuEntries[j].dir = tmp.dir) and (LowerCase(menuEntries[j].name) > LowerCase(tmp.name)))) do begin
      menuEntries[j + 1] := menuEntries[j];
      Dec(j);
    end;
    menuEntries[j + 1] := tmp;
  end;
  SetLength(menuEntries, n + 1);
  for i := n downto 1 do menuEntries[i] := menuEntries[i - 1];
  menuEntries[0].name := '..';
  menuEntries[0].dir := True;
  menuEntries[0].size := 0;
  menuSel := 0;
  menuScroll := 0;
end;

procedure TApp.OpenMenu;
var
  d: string;
begin
  d := ExtractFilePath(ExpandFileName(wins[active].path));
  if (wins[active].path = '') or (d = '') then d := GetCurrentDir;
  MenuLoad(d);
  mode := mMenu;
end;

procedure TApp.MenuKey(const k: TKey);
var
  n, vis, page, i, idx: Integer;
  e: TEntry;
  c: Char;
  p: string;
begin
  n := Length(menuEntries);
  vis := ScreenHeight - 3;
  if vis > 24 then vis := 24;
  vis := vis - 2;
  if vis < 1 then vis := 1;
  page := vis - 1;
  if page < 1 then page := 1;
  case k.kind of
    kEsc: begin mode := mNormal; Exit; end;
    kF: if k.n = 10 then begin mode := mNormal; Exit; end;
    kAlt: if k.ch = 'v' then begin mode := mNormal; Exit; end;
    kUp: if menuSel > 0 then Dec(menuSel);
    kDown: if menuSel < n - 1 then Inc(menuSel);
    kPgUp: begin menuSel := menuSel - page; if menuSel < 0 then menuSel := 0; end;
    kPgDn: begin menuSel := menuSel + page; if menuSel > n - 1 then menuSel := n - 1; end;
    kHome: menuSel := 0;
    kEnd: menuSel := n - 1;
    kChar: begin
      c := LC(k.ch);
      for i := 1 to n do begin
        idx := (menuSel + i) mod n;
        if (menuEntries[idx].name <> '') and (LowerCase(menuEntries[idx].name)[1] = c) then begin
          menuSel := idx;
          Break;
        end;
      end;
    end;
    kEnter: begin
      e := menuEntries[menuSel];
      if e.dir then begin
        if e.name = '..' then MenuLoad(ExtractFileDir(menuDir))
        else MenuLoad(IncludeTrailingPathDelimiter(menuDir) + e.name);
      end else begin
        p := IncludeTrailingPathDelimiter(menuDir) + e.name;
        mode := mNormal;
        idx := files.IndexOf(p);
        if idx < 0 then idx := files.Add(p);
        OpenInActive(idx);
      end;
      Exit;
    end;
  end;
  if menuSel < menuScroll then menuScroll := menuSel
  else if menuSel >= menuScroll + vis then menuScroll := menuSel + 1 - vis;
end;

{ ---------------------------------------------------------------- actions }

procedure TApp.OpenInActive(idx: Integer);
var
  nv: TViewer;
begin
  RememberPos(active);
  try
    nv := OpenViewer(idx);
    nv.fileIdx := idx;
    wins[active].Free;
    wins[active] := nv;
  except
    on E: Exception do msg := files[idx] + ': ' + E.Message;
  end;
end;

{ Q / Esc: go to the next file in the list, close a split window, or exit. }
procedure TApp.QuitNext;
var
  next: Integer;
  t: TViewer;
begin
  if Length(wins) = 2 then begin
    RememberPos(active);
    wins[active].Free;
    if active = 0 then wins[0] := wins[1];
    SetLength(wins, 1);
    active := 0;
    Exit;
  end;
  next := wins[0].fileIdx + 1;
  while next < files.Count do begin
    try
      t := OpenViewer(next);
      t.Free;
      OpenInActive(next);
      Exit;
    except
      Inc(next);
    end;
  end;
  quit := qClear;
end;

{ Install a new search, releasing a previous regex. }
procedure TApp.SetFind(const f: TFind);
var
  i: Integer;
begin
  if hasFind and (find.re <> nil) then find.re.Free;
  find := f;
  hasFind := True;
  for i := 0 to High(wins) do wins[i].lastMatch := -1;
end;

procedure TApp.NewFind(const text: string; ci: Boolean);
begin
  if text <> '' then SetFind(MakeFind(text, ci));
  DoFind(True);
end;

procedure TApp.NewRegex(const pat: string; ci: Boolean);
var
  f: TFind;
begin
  if pat = '' then begin DoFind(True); Exit; end;
  try
    f := MakeRegex(pat, ci);
  except
    on E: Exception do begin
      msg := 'Bad regex: ' + E.Message;
      Exit;
    end;
  end;
  SetFind(f);
  DoFind(True);
end;

{ Search for raw bytes given as hex, e.g. "41 42 0D 0A", "0x41,0x42" or "41420d0a". }
procedure TApp.NewBytes(const arg: string);
var
  digits, tok, s: string;
  i, p: Integer;
  bytes: string;
  ok: Boolean;
begin
  digits := '';
  tok := '';
  s := arg + ' ';
  for i := 1 to Length(s) do begin
    if (s[i] = ' ') or (s[i] = ',') or (s[i] = #9) then begin
      if (Length(tok) > 1) and (tok[1] = '0') and ((tok[2] = 'x') or (tok[2] = 'X')) then Delete(tok, 1, 2);
      digits := digits + tok;
      tok := '';
    end else tok := tok + s[i];
  end;
  ok := (digits <> '') and (Length(digits) mod 2 = 0);
  for i := 1 to Length(digits) do
    if not (digits[i] in ['0'..'9', 'a'..'f', 'A'..'F']) then ok := False;
  if not ok then begin
    msg := 'Give whole hex bytes, e.g. bytes 41 42 0D 0A';
    Exit;
  end;
  bytes := '';
  p := 1;
  while p < Length(digits) do begin
    bytes := bytes + Chr(StrToInt('$' + Copy(digits, p, 2)));
    Inc(p, 2);
  end;
  SetFind(MakeFind(bytes, False));
  DoFind(True);
end;

procedure TApp.ToggleFollow;
var
  v: TViewer;
begin
  v := wins[active];
  v.follow := not v.follow;
  if v.follow then v.GoEnd(opts);
  if v.follow then msg := 'Follow on' else msg := 'Follow off';
end;

procedure TApp.DoFind(fwd: Boolean);
var
  v: TViewer;
  top, bot, from, start, p: Int64;
  hadLast, wrapped, hit: Boolean;
  mlen: Integer;
begin
  if not hasFind then begin
    msg := 'No search text - use / or \ to search';
    Exit;
  end;
  v := wins[active];
  v.follow := False;
  top := v.CurTopOff;
  bot := v.botOff;
  if bot < top + 1 then bot := top + 1;
  hadLast := (v.lastMatch >= 0) and (v.lastMatch >= top) and (v.lastMatch < bot);
  if hadLast then from := v.lastMatch else from := top;
  wrapped := False;
  if fwd then begin
    start := from;
    if hadLast then Inc(start);
    hit := v.Search(find, start, True, p, mlen);
    if not hit then begin wrapped := True; hit := v.Search(find, 0, True, p, mlen); end;
  end else begin
    hit := v.Search(find, from, False, p, mlen);
    if not hit then begin wrapped := True; hit := v.Search(find, v.fileLen, False, p, mlen); end;
  end;
  if hit then begin
    v.lastMatch := p;
    v.lastLen := mlen;
    v.Reveal(p, opts);
    if wrapped then msg := '*** Search wrapped ***' else msg := '';
  end else
    msg := '*** Text not found ***';
end;

procedure TApp.GotoStr(const s: string);
var
  t: string;
  v: TViewer;
  n, off: Int64;
  h: string;
begin
  v := wins[active];
  v.follow := False;
  t := Trim(s);
  h := '';
  if (t <> '') and (t[1] = '$') then h := Copy(t, 2, MaxInt)
  else if (Length(t) > 2) and (t[1] = '0') and ((t[2] = 'x') or (t[2] = 'X')) then h := Copy(t, 3, MaxInt);
  if h <> '' then begin
    off := StrToInt64Def('$' + h, -1);
    if off < 0 then msg := 'Bad offset: ' + t
    else begin
      if off > v.fileLen - 1 then off := v.fileLen - 1;
      if off < 0 then off := 0;
      v.GotoOff(off, opts);
    end;
  end else begin
    n := StrToInt64Def(t, -1);
    if n < 0 then msg := 'Bad line number: ' + t
    else begin
      if n > 0 then Dec(n);
      v.GotoLine(n, opts);
    end;
  end;
end;

procedure TApp.CmdMem(const arg: string);
var
  n: Int64;
  i: Integer;
begin
  if arg = '' then begin
    msg := 'Max memory per file: ' + FmtSize(opts.maxMem) + '  (mem SIZE to change, Alt-C saves)';
    Exit;
  end;
  if ParseSize(arg, n) then begin
    opts.maxMem := n;
    for i := 0 to High(wins) do wins[i].SetLimit(n);
    msg := 'Max memory per file: ' + FmtSize(opts.maxMem);
  end else
    msg := 'Bad size: ' + arg + ' (try 512K, 1M, 8M)';
end;

procedure TApp.CmdOpen(const spec: string; insert: Boolean);
var
  found: TStringList;
  i, cur, at: Integer;
begin
  if spec = '' then begin OpenMenu; Exit; end;
  found := TStringList.Create;
  try
    ExpandSpec(spec, found);
    if found.Count = 0 then begin msg := 'No files match ' + spec; Exit; end;
    cur := wins[active].fileIdx;
    if insert and (files.Count > 0) then at := cur + 1 else at := 0;
    if insert then begin
      for i := 0 to found.Count - 1 do files.Insert(at + i, found[i]);
    end else begin
      files.Clear;
      files.AddStrings(found);
    end;
  finally
    found.Free;
  end;
  OpenInActive(at);
end;

procedure TApp.CmdWrite(const name: string; append: Boolean);
var
  b: TByteArr;
  fs: TFileStream;
begin
  if name = '' then begin msg := 'Give a file name'; Exit; end;
  if not wins[active].Block(b) then begin
    msg := 'Mark a block first: Alt-M (top line) and Alt-B (bottom line)';
    Exit;
  end;
  try
    if append then begin
      if FileExists(name) then begin
        fs := TFileStream.Create(name, fmOpenReadWrite);
        fs.Seek(0, soEnd);
      end else fs := TFileStream.Create(name, fmCreate);
    end else begin
      if FileExists(name) then begin
        msg := name + ' exists - use append (Alt-O) or another name';
        Exit;
      end;
      fs := TFileStream.Create(name, fmCreate);
    end;
    try
      fs.WriteBuffer(b[0], Length(b));
    finally
      fs.Free;
    end;
    if append then msg := IntToStr(Length(b)) + ' bytes appended to ' + name
    else msg := IntToStr(Length(b)) + ' bytes copied to ' + name;
  except
    on E: Exception do msg := name + ': ' + E.Message;
  end;
end;

procedure TApp.PrintMarked;
var
  b: TByteArr;
  tmp: string;
  fs: TFileStream;
  {$IFDEF WINDOWS}
  f: file;
  {$ENDIF}
begin
  if not opts.printer then begin msg := 'Printer is off - press P to turn it on'; Exit; end;
  if not wins[active].Block(b) then begin
    msg := 'Mark a block first: Alt-M (top line) and Alt-B (bottom line)';
    Exit;
  end;
  try
    {$IFDEF WINDOWS}
    AssignFile(f, 'PRN');
    Rewrite(f, 1);
    BlockWrite(f, b[0], Length(b));
    CloseFile(f);
    {$ELSE}
    tmp := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'list-print-' + IntToStr(GetProcessID) + '.tmp';
    fs := TFileStream.Create(tmp, fmCreate);
    try
      fs.WriteBuffer(b[0], Length(b));
    finally
      fs.Free;
    end;
    fpSystem('lp ' + tmp + ' >/dev/null 2>&1; rm -f ' + tmp);
    {$ENDIF}
    msg := IntToStr(Length(b)) + ' bytes sent to printer';
  except
    on E: Exception do msg := 'Print failed: ' + E.Message;
  end;
end;

{ ---------------------------------------------------------------- command line }

procedure TApp.Exec(const s: string);
var
  t, cmd, arg, rest: string;
  p: Integer;
  n: Int64;
  c: Char;
  v: TViewer;
begin
  t := Trim(s);
  if t = '' then Exit;
  v := wins[active];
  c := t[1];
  rest := Copy(t, 2, MaxInt);
  case c of
    '/': begin NewFind(rest, True); Exit; end;
    '\': begin NewFind(rest, False); Exit; end;
    '#': begin GotoStr(rest); Exit; end;
    '$': begin GotoStr(t); Exit; end;
    '+', '-': begin
      n := StrToInt64Def(Trim(rest), -1);
      if n < 0 then msg := 'Bad number: ' + rest
      else if c = '+' then v.Down(n, opts) else v.Up(n, opts);
      Exit;
    end;
    '0'..'9': begin GotoStr(t); Exit; end;
  end;
  p := Pos(' ', t);
  if p = 0 then begin cmd := LowerCase(t); arg := ''; end
  else begin cmd := LowerCase(Copy(t, 1, p - 1)); arg := Trim(Copy(t, p + 1, MaxInt)); end;
  if (cmd = 'goto') or (cmd = 'go') or (cmd = 'g') or (cmd = 'line') or (cmd = 'skip') then GotoStr(arg)
  else if (cmd = 'find') or (cmd = 'f') then NewFind(arg, True)
  else if (cmd = 'exact') or (cmd = 'fe') then NewFind(arg, False)
  else if (cmd = 're') or (cmd = 'regex') then NewRegex(arg, True)
  else if cmd = 'rex' then NewRegex(arg, False)
  else if (cmd = 'bytes') or (cmd = 'hexfind') or (cmd = 'xfind') then NewBytes(arg)
  else if (cmd = 'follow') or (cmd = 'tail') then ToggleFollow
  else if cmd = 'remember' then begin
    opts.remember := not opts.remember;
    if opts.remember then msg := 'Remember positions on' else msg := 'Remember positions off';
  end
  else if (cmd = 'next') or (cmd = 'findnext') then DoFind(True)
  else if (cmd = 'prev') or (cmd = 'findprev') then DoFind(False)
  else if cmd = 'hex' then v.ToggleHex
  else if cmd = 'text' then begin if v.hex then v.ToggleHex; end
  else if cmd = 'wrap' then PlainKey('w')
  else if cmd = 'tabs' then opts.tabs := not opts.tabs
  else if cmd = 'ruler' then opts.ruler := not opts.ruler
  else if cmd = 'junk' then opts.junk := not opts.junk
  else if cmd = 'hibit' then begin
    if arg = '7' then opts.hibit := 1 else if arg = '*' then opts.hibit := 2 else opts.hibit := 0;
  end
  else if (cmd = 'open') or (cmd = 'o') or (cmd = 'get') then CmdOpen(arg, False)
  else if (cmd = 'insert') or (cmd = 'i') then CmdOpen(arg, True)
  else if (cmd = 'files') or (cmd = 'menu') then OpenMenu
  else if cmd = 'nextfile' then QuitNext
  else if cmd = 'firstfile' then PlainKey('1')
  else if (cmd = 'quit') or (cmd = 'q') then QuitNext
  else if (cmd = 'exit') or (cmd = 'x') or (cmd = 'bye') then quit := qClear
  else if cmd = 'copy' then CmdWrite(arg, False)
  else if cmd = 'append' then CmdWrite(arg, True)
  else if cmd = 'print' then PrintMarked
  else if cmd = 'mark' then begin
    if (arg = 'top') or (arg = 't') then AltKey('m')
    else if (arg = 'bottom') or (arg = 'bot') or (arg = 'b') then AltKey('b')
    else AltKey('u');
  end
  else if cmd = 'unmark' then AltKey('u')
  else if (cmd = 'bookmark') or (cmd = 'bm') then AltKey('m')
  else if cmd = 'recall' then AltKey('y')
  else if (cmd = 'windows') or (cmd = 'win') then AltKey('w')
  else if cmd = 'rows' then AltKey('e')
  else if cmd = 'save' then AltKey('c')
  else if (cmd = 'mem') or (cmd = 'maxmem') then CmdMem(arg)
  else if (cmd = 'toggles') or (cmd = 'show') then mode := mToggles
  else if (cmd = 'dos') or (cmd = 'shell') or (cmd = 'sh') then shellReq := True
  else if (cmd = 'help') or (cmd = '?') then begin mode := mHelp; helpPage := 0; end
  else msg := 'Unknown command: ' + cmd + '  (F1 for help)';
end;

end.
