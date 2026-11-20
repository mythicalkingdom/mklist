unit uViewer;
{$mode objfpc}{$H+}
{$POINTERMATH ON}
{ One open file plus its view state: text mode, hex mode, scrolling, search and marks.
  Only up to Opts.maxMem bytes of a file are held in memory; the buffer is reloaded, centred on the
  current position, when the view comes near either of its edges. }

interface

uses SysUtils, RegExpr, uOpts, uCP437, uScreen;

const
  MIN_LIMIT = 64 * 1024;
  HEX_X = 9;
  ASC_X = 61;

type
  TByteArr = array of Byte;
  TFind = record
    needle: string;        { raw bytes (lower-cased when ci); for a regex, the pattern }
    ci: Boolean;
    re: TRegExpr;          { non-nil for a regex search; owned by whoever created the TFind }
  end;
  PFind = ^TFind;
  { fl: style bits (SF_*); fg/bg: VGA colour 0..15, or -1 for the normal text colour }
  TCl = record ch: Byte; src: Int64; fl: Byte; fg, bg: ShortInt; end;
  TCellList = record a: array of TCl; n: Integer; end;
  TMatch = record start: Int64; len: Integer; end;
  TMatchArr = array of TMatch;
  TAnchor = record off, nl: Int64; end;

  TViewer = class
  public
    path, name, mtime: string;
    data: TByteArr;
    starts: array of Cardinal;
    utf8: Boolean;
    isMd: Boolean;         { the file name says Markdown }
    base, lineBase, fileLen, limit: Int64;
    lbValid: Boolean;
    anchors: array of TAnchor;
    isStream, streamDone, wasDone: Boolean;
    fileIdx: Integer;
    hex: Boolean;
    top, sub, col: Integer;
    markTop, markBot, bookmark, lastMatch: Int64;   { -1 = none }
    lastLen: Integer;
    follow: Boolean;
    vw, vh, maxW: Integer;
    first, last: Int64;
    byOffset, atEof: Boolean;
    botOff: Int64;

    constructor Create;
    procedure Assign(src: TViewer);
    procedure OpenFile(const APath: string; ALimit: Int64);
    procedure MakeStream(const AName: string);
    function InputPending: Boolean;
    function Refresh(const o: TOpts): Boolean;
    function LooksBinary: Boolean;
    function Windowed: Boolean;
    function AtEnd: Boolean;
    function CurTopOff: Int64;
    procedure SetLimit(ALimit: Int64);
    procedure Recenter(abs: Int64);
    function Search(const f: TFind; from: Int64; fwd: Boolean; out mpos: Int64; out mlen: Integer): Boolean;
    function NLines: Integer;
    procedure Down(n: Integer; const o: TOpts);
    procedure Up(n: Integer; const o: TOpts);
    procedure GoHome;
    procedure GoEnd(const o: TOpts);
    procedure GotoRow(n: Integer; const o: TOpts);
    procedure GotoOff(abs: Int64; const o: TOpts);
    procedure GotoLine(n: Int64; const o: TOpts);
    procedure ToggleHex;
    procedure Reveal(abs: Int64; const o: TOpts);
    function Block(out b: TByteArr): Boolean;
    procedure Render(y0, h, w: Integer; const o: TOpts; f: PFind; active: Boolean);
  private
    function ReadAt(off, len: Int64; out buf: TByteArr): Int64;
    procedure Load(center: Int64);
    function CountNlMem(a, b: Int64): Int64;
    function CountNlFile(a, b: Int64): Int64;
    function NlBefore(off: Int64): Int64;
    procedure AddAnchor(off, nl: Int64);
    function MaybeReload: Boolean;
    function OffsetOfLine(n: Int64; out exact: Boolean): Int64;
    function Rel(abs: Int64): Int64;
    function InBuf(abs: Int64): Boolean;
    procedure LineContent(i: Integer; out s, e: Int64);
    function LineEndFull(i: Integer): Int64;
    function LineOf(off: Int64): Integer;
    procedure LineCells(i: Integer; const o: TOpts; var cl: TCellList);
    function RowsOf(i: Integer; const o: TOpts): Integer;
    function Remaining(const o: TOpts): Int64;
    function EofVisible(const o: TOpts): Boolean;
    function StepDown(const o: TOpts): Boolean;
    function StepUp(const o: TOpts): Boolean;
    function Total: Integer;
    function NRowsHex: Integer;
    function MaxTop: Integer;
    function LineVisible(line: Integer; const o: TOpts): Boolean;
    function Marked(rp: Int64): Boolean;
    function Matches(const f: TFind; from, till: Int64): TMatchArr;
    procedure RenderInner(y0, h, w: Integer; const o: TOpts; f: PFind; active: Boolean);
    procedure RenderText(y0, w: Integer; const o: TOpts; f: PFind);
    procedure RenderHex(y0, w: Integer; const o: TOpts; f: PFind);
  end;

function MakeFind(const text: string; ci: Boolean): TFind;
{ Compile a regular expression (matched byte-wise, line by line); raises ERegExpr if it is bad. }
function MakeRegex(const pat: string; ci: Boolean): TFind;
{ First match starting at or after `from`; returns its start (or -1) and length. }
function FindFwd(const d: TByteArr; const f: TFind; from: Int64; out mlen: Integer): Int64;
{ Last match starting strictly before `before`. }
function FindBack(const d: TByteArr; const f: TFind; before: Int64; out mlen: Integer): Int64;

implementation

{ ---------------------------------------------------------------- helpers }

function Lower(c: Byte): Byte; inline;
begin
  if (c >= 65) and (c <= 90) then Result := c + 32 else Result := c;
end;

function PadL(const s: string; n: Integer): string;
var
  k: Integer;
begin
  k := Utf8Len(s);
  if k >= n then Result := s else Result := StringOfChar(' ', n - k) + s;
end;

function PadR(const s: string; n: Integer): string;
var
  k: Integer;
begin
  k := Utf8Len(s);
  if k >= n then Result := s else Result := s + StringOfChar(' ', n - k);
end;

function MakeFind(const text: string; ci: Boolean): TFind;
var
  i: Integer;
begin
  Result.needle := text;
  Result.ci := ci;
  Result.re := nil;
  if ci then
    for i := 1 to Length(text) do
      if (text[i] >= 'A') and (text[i] <= 'Z') then Result.needle[i] := Chr(Ord(text[i]) + 32);
end;

function MakeRegex(const pat: string; ci: Boolean): TFind;
begin
  Result.needle := pat;
  Result.ci := ci;
  Result.re := TRegExpr.Create;
  try
    Result.re.ModifierI := ci;
    Result.re.ModifierS := False;     { . does not match a newline }
    Result.re.ModifierM := True;      { ^ and $ match at line boundaries }
    Result.re.Expression := pat;
    Result.re.Compile;
  except
    Result.re.Free;
    Result.re := nil;
    raise;
  end;
end;

function BytesToStr(const d: TByteArr; a, b: Int64): RawByteString;
begin
  SetLength(Result, b - a);
  if b > a then Move(d[a], Result[1], b - a);
end;

function ReFwd(const d: TByteArr; const f: TFind; from: Int64; out mlen: Integer): Int64;
var
  s: RawByteString;
  p: Integer;
begin
  Result := -1;
  mlen := 0;
  if from < 0 then from := 0;
  if from >= Length(d) then Exit;
  s := BytesToStr(d, 0, Length(d));
  f.re.InputString := s;
  p := from + 1;
  while p <= Length(s) do begin
    if not f.re.ExecPos(p) then Exit;
    if f.re.MatchLen[0] > 0 then begin
      mlen := f.re.MatchLen[0];
      Exit(f.re.MatchPos[0] - 1);
    end;
    p := f.re.MatchPos[0] + 1;
  end;
end;

function ReBack(const d: TByteArr; const f: TFind; before: Int64; out mlen: Integer): Int64;
var
  s: RawByteString;
  p, ms, ml: Integer;
begin
  Result := -1;
  mlen := 0;
  if (before <= 0) or (Length(d) = 0) then Exit;
  s := BytesToStr(d, 0, Length(d));
  f.re.InputString := s;
  p := 1;
  while p <= Length(s) do begin
    if not f.re.ExecPos(p) then Break;
    ms := f.re.MatchPos[0] - 1;
    ml := f.re.MatchLen[0];
    if ms >= before then Break;
    if ml > 0 then begin
      Result := ms;
      mlen := ml;
      p := ms + ml + 1;      { matches do not overlap }
    end else
      p := ms + 2;
  end;
end;

function FindFwd(const d: TByteArr; const f: TFind; from: Int64; out mlen: Integer): Int64;
var
  n, len, lastStart, i, j: Int64;
  n0, c: Byte;
  ok: Boolean;
begin
  Result := -1;
  mlen := Length(f.needle);
  if f.re <> nil then Exit(ReFwd(d, f, from, mlen));
  n := Length(f.needle);
  len := Length(d);
  if (n = 0) or (len < n) then Exit;
  lastStart := len - n;
  if from < 0 then from := 0;
  if from > lastStart then Exit;
  n0 := Byte(f.needle[1]);
  i := from;
  while i <= lastStart do begin
    c := d[i];
    if f.ci then c := Lower(c);
    if c = n0 then begin
      ok := True;
      for j := 1 to n - 1 do begin
        c := d[i + j];
        if f.ci then c := Lower(c);
        if c <> Byte(f.needle[j + 1]) then begin ok := False; Break; end;
      end;
      if ok then Exit(i);
    end;
    Inc(i);
  end;
end;

function FindBack(const d: TByteArr; const f: TFind; before: Int64; out mlen: Integer): Int64;
var
  n, len, i, j: Int64;
  n0, c: Byte;
  ok: Boolean;
begin
  Result := -1;
  mlen := Length(f.needle);
  if f.re <> nil then Exit(ReBack(d, f, before, mlen));
  n := Length(f.needle);
  len := Length(d);
  if (n = 0) or (before <= 0) or (len < n) then Exit;
  i := before - 1;
  if i > len - n then i := len - n;
  n0 := Byte(f.needle[1]);
  while i >= 0 do begin
    c := d[i];
    if f.ci then c := Lower(c);
    if c = n0 then begin
      ok := True;
      for j := 1 to n - 1 do begin
        c := d[i + j];
        if f.ci then c := Lower(c);
        if c <> Byte(f.needle[j + 1]) then begin ok := False; Break; end;
      end;
      if ok then Exit(i);
    end;
    Dec(i);
  end;
end;

const
  SF_BOLD = 1; SF_UL = 2; SF_REV = 4;
  { the text screen has no bold or underline, so they are shown as colours }
  BOLD_FG = 14; UL_FG = 11; BOLDUL_FG = 10;

var
  curFl: Byte = 0;            { the style in force while LineCells builds a line }
  curFg: ShortInt = -1;
  curBg: ShortInt = -1;

procedure AddCell(var cl: TCellList; ch: Byte; src: Int64);
begin
  if cl.n >= Length(cl.a) then SetLength(cl.a, Length(cl.a) * 2 + 64);
  cl.a[cl.n].ch := ch;
  cl.a[cl.n].src := src;
  cl.a[cl.n].fl := curFl;
  cl.a[cl.n].fg := curFg;
  cl.a[cl.n].bg := curBg;
  Inc(cl.n);
end;

procedure EmitByte(var cl: TCellList; b: Byte; src: Int64; const o: TOpts);
begin
  if b = 9 then begin
    if o.tabs then begin
      repeat AddCell(cl, 32, src) until cl.n mod 8 = 0;
    end else if not o.junk then AddCell(cl, 9, src);
    Exit;
  end;
  if (b < 32) or (b = 127) then begin
    if o.junk then Exit;
    if b = 0 then b := 32;
  end;
  AddCell(cl, b, src);
end;

procedure EmitCp(var cl: TCellList; cp: Cardinal; src: Int64; const o: TOpts);
var
  m: Integer;
begin
  if cp < 128 then begin EmitByte(cl, Byte(cp), src, o); Exit; end;
  if (cp >= $80) and (cp <= $9F) then begin
    if not o.junk then AddCell(cl, $FA, src);
    Exit;
  end;
  if IsZeroWidth(cp) then Exit;
  m := UniToCp437(cp);
  if m < 0 then AddCell(cl, 63, src) else AddCell(cl, m, src);
end;


{ ANSI colour number 0..7 (bit0 red, bit1 green, bit2 blue) -> VGA colour (bit0 blue, bit2 red) }
function AnsiToVga(n: Integer): Integer;
begin
  Result := ((n and 1) shl 2) or (n and 2) or ((n and 4) shr 2);
end;

function Rgb16(r, g, b: Integer): Integer;
var
  m: Integer;
begin
  m := r;
  if g > m then m := g;
  if b > m then m := b;
  if m < 48 then Exit(0);
  Result := 0;
  if r * 2 >= m then Result := Result or 4;
  if g * 2 >= m then Result := Result or 2;
  if b * 2 >= m then Result := Result or 1;
  if (Result = 7) and (m < 160) then Result := 8
  else if (m >= 200) and (Result <> 7) then Result := Result or 8
  else if Result = 7 then Result := 7;
  if (Result = 7) and (m >= 230) then Result := 15;
end;

function Color256(n: Integer): Integer;
var
  r, g, b, v: Integer;
begin
  if n < 8 then Exit(AnsiToVga(n));
  if n < 16 then Exit(AnsiToVga(n - 8) + 8);
  if n >= 232 then begin
    v := (n - 232) * 10 + 8;
    Exit(Rgb16(v, v, v));
  end;
  n := n - 16;
  b := n mod 6; g := (n div 6) mod 6; r := n div 36;
  Result := Rgb16(r * 51, g * 51, b * 51);
end;

procedure ApplySgr(const params: array of Integer; np: Integer);
var
  i, c: Integer;
begin
  if np = 0 then begin curFl := 0; curFg := -1; curBg := -1; Exit; end;
  i := 0;
  while i < np do begin
    c := params[i];
    case c of
      0: begin curFl := 0; curFg := -1; curBg := -1; end;
      1: curFl := curFl or SF_BOLD;
      3, 4: curFl := curFl or SF_UL;
      7: curFl := curFl or SF_REV;
      22: curFl := curFl and not SF_BOLD;
      23, 24: curFl := curFl and not SF_UL;
      27: curFl := curFl and not SF_REV;
      30..37: curFg := AnsiToVga(c - 30);
      39: curFg := -1;
      40..47: curBg := AnsiToVga(c - 40);
      49: curBg := -1;
      90..97: curFg := AnsiToVga(c - 90) + 8;
      100..107: curBg := AnsiToVga(c - 100);
      38, 48: begin
        if (i + 2 < np) and (params[i + 1] = 5) then begin
          if c = 38 then curFg := Color256(params[i + 2]) else curBg := Color256(params[i + 2]) and 7;
          Inc(i, 2);
        end else if (i + 4 < np) and (params[i + 1] = 2) then begin
          if c = 38 then curFg := Rgb16(params[i + 2], params[i + 3], params[i + 4])
          else curBg := Rgb16(params[i + 2], params[i + 3], params[i + 4]) and 7;
          Inc(i, 4);
        end;
      end;
    end;
    Inc(i);
  end;
end;

{ p points at an ESC. Interprets (SGR) or skips the escape sequence and returns its length. }
function EscSeq(const d: TByteArr; p, e: Int64): Integer;
var
  q: Int64;
  params: array[0..15] of Integer;
  np, v: Integer;
  have: Boolean;
begin
  Result := 1;
  if p + 1 >= e then Exit;
  case d[p + 1] of
    Ord('['): begin
      q := p + 2;
      np := 0; v := 0; have := False;
      while (q < e) and (d[q] >= $30) and (d[q] <= $3F) do begin
        if (d[q] >= 48) and (d[q] <= 57) then begin
          if v < 100000 then v := v * 10 + d[q] - 48;
          have := True;
        end else if d[q] = Ord(';') then begin
          if np < 16 then begin params[np] := v; Inc(np); end;
          v := 0; have := False;
        end;
        Inc(q);
      end;
      if have or (np > 0) then if np < 16 then begin params[np] := v; Inc(np); end;
      while (q < e) and (d[q] >= $20) and (d[q] <= $2F) do Inc(q);
      if q >= e then Exit(Integer(q - p));       { truncated: swallow what there is }
      if (d[q] >= $40) and (d[q] <= $7E) then begin
        if d[q] = Ord('m') then ApplySgr(params, np);
        Exit(Integer(q - p + 1));
      end;
      Result := Integer(q - p);
    end;
    Ord(']'), Ord('P'), Ord('_'), Ord('^'): begin    { OSC (e.g. hyperlinks), DCS...: up to BEL or ST }
      q := p + 2;
      while q < e do begin
        if d[q] = 7 then Exit(Integer(q - p + 1));
        if (d[q] = 27) and (q + 1 < e) and (d[q + 1] = Ord('\')) then Exit(Integer(q - p + 2));
        Inc(q);
      end;
      Result := Integer(e - p);
    end;
    $20..$2F: begin                                  { ESC ( B and friends }
      Result := 3;
      if p + Result > e then Result := Integer(e - p);
    end;
    else Result := 2;
  end;
end;


{ ---------------------------------------------------------------- Markdown (single-line constructs only)
  Works on the cells of one line after they are built: markers are removed and the text restyled.
  Multi-line constructs (fenced blocks, tables, setext headings) are not recognised. }

const
  MD_BOLD = 1; MD_ITAL = 2; MD_CODE = 4; MD_LINK = 8;
  MD_HEAD_FG = 14; MD_QUOTE_FG = 7; MD_BULLET_FG = 14;
  MD_BOLD_FG = 10; MD_ITAL_FG = 13; MD_BOTH_FG = 12; MD_LINK_FG = 11;
  MD_CODE_FG = 0; MD_CODE_BG = 7;

function MdPunct(c: Byte): Boolean;
begin
  Result := ((c >= 33) and (c <= 47)) or ((c >= 58) and (c <= 64)) or ((c >= 91) and (c <= 96)) or ((c >= 123) and (c <= 126));
end;

function MdAlnum(c: Byte): Boolean;
begin
  Result := ((c >= 48) and (c <= 57)) or ((c >= 65) and (c <= 90)) or ((c >= 97) and (c <= 122)) or (c >= 128);
end;

procedure MdPass(var cl: TCellList; vw: Integer);
var
  n, i, j, k, m, r, ind, hn, outN: Integer;
  kill: array of Boolean;
  mf: array of Byte;
  code: Boolean;
  c: Byte;
  baseFg: Integer;
  nl: array of TCl;

  function Ch(x: Integer): Byte;
  begin
    if (x < 0) or (x >= n) then Result := 0 else Result := cl.a[x].ch;
  end;

  procedure MarkRange(a, b: Integer; bits: Byte);
  var x: Integer;
  begin
    for x := a to b do mf[x] := mf[x] or bits;
  end;

begin
  n := cl.n;
  if (n = 0) or (n > 2000) then Exit;
  SetLength(kill, n);
  SetLength(mf, n);
  for i := 0 to n - 1 do begin kill[i] := False; mf[i] := 0; end;
  baseFg := -1;
  ind := 0;
  while (ind < n) and (cl.a[ind].ch = 32) do Inc(ind);
  if ind >= n then Exit;

  { horizontal rule: 3+ of - * _ (spaces allowed) and nothing else }
  c := cl.a[ind].ch;
  if (c = Ord('-')) or (c = Ord('*')) or (c = Ord('_')) then begin
    k := 0; j := ind;
    while (j < n) and ((cl.a[j].ch = c) or (cl.a[j].ch = 32)) do begin
      if cl.a[j].ch = c then Inc(k);
      Inc(j);
    end;
    if (j >= n) and (k >= 3) then begin
      m := vw;
      if m < 3 then m := 3;
      SetLength(nl, m);
      for i := 0 to m - 1 do begin
        nl[i] := cl.a[0];
        nl[i].ch := $C4; nl[i].fl := 0; nl[i].fg := MD_QUOTE_FG; nl[i].bg := -1;
      end;
      if Length(cl.a) < m then SetLength(cl.a, m);
      for i := 0 to m - 1 do cl.a[i] := nl[i];
      cl.n := m;
      Exit;
    end;
  end;

  { fence line: shown as code, not parsed further }
  if (ind + 2 < n) and (((c = Ord('`')) and (Ch(ind + 1) = c) and (Ch(ind + 2) = c)) or
     ((c = Ord('~')) and (Ch(ind + 1) = c) and (Ch(ind + 2) = c))) then begin
    for i := 0 to n - 1 do begin cl.a[i].fl := 0; cl.a[i].fg := MD_CODE_FG; cl.a[i].bg := MD_CODE_BG; end;
    Exit;
  end;

  { block prefixes }
  i := ind;
  if (c = Ord('#')) and (ind <= 3) then begin
    hn := 0; j := ind;
    while (j < n) and (cl.a[j].ch = Ord('#')) do begin Inc(hn); Inc(j); end;
    if (hn <= 6) and ((j >= n) or (cl.a[j].ch = 32)) then begin
      for k := ind to j - 1 do kill[k] := True;
      if j < n then kill[j] := True;
      baseFg := MD_HEAD_FG;
      i := j;
    end;
  end else if c = Ord('>') then begin
    k := ind;
    while (k < n) and (cl.a[k].ch = Ord('>')) do begin
      kill[k] := True; Inc(k);
      if (k < n) and (cl.a[k].ch = 32) then begin kill[k] := True; Inc(k); end;
    end;
    baseFg := MD_QUOTE_FG;
    i := k;
  end else if ((c = Ord('-')) or (c = Ord('*')) or (c = Ord('+'))) and (Ch(ind + 1) = 32) then begin
    cl.a[ind].ch := 7; cl.a[ind].fg := MD_BULLET_FG;
    i := ind + 2;
  end else if (c >= 48) and (c <= 57) then begin
    j := ind;
    while (j < n) and (cl.a[j].ch >= 48) and (cl.a[j].ch <= 57) do Inc(j);
    if (j < n) and (j - ind <= 9) and ((cl.a[j].ch = Ord('.')) or (cl.a[j].ch = Ord(')'))) and (Ch(j + 1) = 32) then begin
      for k := ind to j do cl.a[k].fg := MD_BULLET_FG;
      i := j + 2;
    end;
  end;

  { inline constructs from i onwards }
  while i < n do begin
    if kill[i] then begin Inc(i); Continue; end;
    c := cl.a[i].ch;
    if (c = Ord('\')) and MdPunct(Ch(i + 1)) then begin
      kill[i] := True; Inc(i, 2); Continue;
    end;
    if c = Ord('`') then begin
      r := 0;
      while Ch(i + r) = Ord('`') do Inc(r);
      j := i + r;
      m := -1;
      while j < n do begin
        if cl.a[j].ch = Ord('`') then begin
          k := 0;
          while Ch(j + k) = Ord('`') do Inc(k);
          if k = r then begin m := j; Break; end;
          Inc(j, k);
        end else Inc(j);
      end;
      if m < 0 then begin Inc(i, r); Continue; end;
      for k := i to i + r - 1 do kill[k] := True;
      for k := m to m + r - 1 do kill[k] := True;
      MarkRange(i + r, m - 1, MD_CODE);
      i := m + r;
      Continue;
    end;
    if c = Ord('[') then begin
      k := i + 1;
      while (k < n) and (cl.a[k].ch <> Ord(']')) do Inc(k);
      if (k + 1 < n) and (Ch(k + 1) = Ord('(')) then begin
        m := k + 2;
        while (m < n) and (cl.a[m].ch <> Ord(')')) do Inc(m);
        if m < n then begin
          kill[i] := True;
          for j := k to m do kill[j] := True;
          MarkRange(i + 1, k - 1, MD_LINK);
          i := m + 1;
          Continue;
        end;
      end;
      Inc(i);
      Continue;
    end;
    if (c = Ord('*')) or (c = Ord('_')) then begin
      r := 1;
      if Ch(i + 1) = c then r := 2;
      if (Ch(i + r) <> 0) and (Ch(i + r) <> 32) and not ((c = Ord('_')) and MdAlnum(Ch(i - 1))) then begin
        m := -1;
        j := i + r;
        while j < n do begin
          if (not kill[j]) and (cl.a[j].ch = c) and ((r = 1) or (Ch(j + 1) = c)) and (Ch(j - 1) <> 32)
             and (j > i + r) and not ((c = Ord('_')) and MdAlnum(Ch(j + r))) then begin
            m := j; Break;
          end;
          Inc(j);
        end;
        if m >= 0 then begin
          for k := i to i + r - 1 do kill[k] := True;
          for k := m to m + r - 1 do kill[k] := True;
          if r = 2 then MarkRange(i + r, m - 1, MD_BOLD) else MarkRange(i + r, m - 1, MD_ITAL);
          Inc(i, r);
          Continue;
        end;
      end;
      Inc(i, r);
      Continue;
    end;
    Inc(i);
  end;

  { apply styles and drop the marker cells }
  outN := 0;
  for i := 0 to n - 1 do begin
    if kill[i] then Continue;
    if (baseFg >= 0) and (cl.a[i].fg < 0) then cl.a[i].fg := baseFg;
    if (mf[i] and MD_CODE) <> 0 then begin
      cl.a[i].fl := 0; cl.a[i].fg := MD_CODE_FG; cl.a[i].bg := MD_CODE_BG;
    end else if (mf[i] and MD_LINK) <> 0 then cl.a[i].fg := MD_LINK_FG
    else if (mf[i] and (MD_BOLD or MD_ITAL)) = (MD_BOLD or MD_ITAL) then cl.a[i].fg := MD_BOTH_FG
    else if (mf[i] and MD_BOLD) <> 0 then cl.a[i].fg := MD_BOLD_FG
    else if (mf[i] and MD_ITAL) <> 0 then cl.a[i].fg := MD_ITAL_FG;
    cl.a[outN] := cl.a[i];
    Inc(outN);
  end;
  cl.n := outN;
end;

{ ---------------------------------------------------------------- construction / loading }

constructor TViewer.Create;
begin
  inherited Create;
  path := ''; name := ''; mtime := '';
  SetLength(data, 0); SetLength(starts, 0);
  utf8 := True; isMd := False;
  base := 0; lineBase := 0; fileLen := 0; limit := 1 shl 20;
  lbValid := True;
  SetLength(anchors, 1); anchors[0].off := 0; anchors[0].nl := 0;
  isStream := False; streamDone := False; wasDone := False;
  fileIdx := 0; hex := False; top := 0; sub := 0; col := 0;
  markTop := -1; markBot := -1; bookmark := -1; lastMatch := -1; lastLen := 0;
  follow := False;
  vw := 80; vh := 22; maxW := 0; first := 0; last := 0;
  byOffset := False; atEof := True; botOff := 0;
end;

procedure TViewer.Assign(src: TViewer);
begin
  path := src.path; name := src.name; mtime := src.mtime;
  data := src.data; starts := src.starts; utf8 := src.utf8; isMd := src.isMd;
  base := src.base; lineBase := src.lineBase; fileLen := src.fileLen; limit := src.limit;
  lbValid := src.lbValid; anchors := Copy(src.anchors);
  isStream := src.isStream; streamDone := src.streamDone; wasDone := src.wasDone;
  fileIdx := src.fileIdx; hex := src.hex; top := src.top; sub := src.sub; col := src.col;
  markTop := src.markTop; markBot := src.markBot; bookmark := src.bookmark;
  lastMatch := src.lastMatch; lastLen := src.lastLen; follow := src.follow;
  vw := src.vw; vh := src.vh; maxW := src.maxW; first := src.first; last := src.last;
  byOffset := src.byOffset; atEof := src.atEof; botOff := src.botOff;
end;

function ValidUtf8(const d: TByteArr): Boolean;
var
  i, n: Int64;
  k: Integer;
  cp: Cardinal;
begin
  Result := True;
  i := 0;
  n := Length(d);
  while i < n do begin
    if d[i] < $80 then Inc(i)
    else begin
      k := Utf8Decode(@d[i], n - i, cp);
      if k = 0 then Exit(False);
      Inc(i, k);
    end;
  end;
end;

procedure TViewer.OpenFile(const APath: string; ALimit: Int64);
var
  ext: string;
  sr: TSearchRec;
  dt: TDateTime;
  age: LongInt;
begin
  if DirectoryExists(APath) then raise Exception.Create('is a directory');
  if FindFirst(APath, faAnyFile, sr) <> 0 then raise Exception.Create('cannot open file');
  fileLen := sr.Size;
  FindClose(sr);
  path := APath;
  name := ExtractFileName(APath);
  ext := LowerCase(ExtractFileExt(APath));
  isMd := (ext = '.md') or (ext = '.markdown') or (ext = '.mdown');
  age := FileAge(APath);
  if age <> -1 then begin
    dt := FileDateToDateTime(age);
    mtime := FormatDateTime('mm-dd-yy hh:nn', dt);
  end;
  limit := ALimit;
  if limit < MIN_LIMIT then limit := MIN_LIMIT;
  Load(0);
  utf8 := ValidUtf8(data);
end;

procedure TViewer.MakeStream(const AName: string);
begin
  name := AName;
  mtime := '';
  isStream := True;
end;

function TViewer.InputPending: Boolean;
begin
  Result := isStream and not streamDone;
end;

function TViewer.ReadAt(off, len: Int64; out buf: TByteArr): Int64;
var
  h: THandle;
  got, want, tot: Int64;
begin
  SetLength(buf, 0);
  Result := 0;
  if len <= 0 then Exit;
  h := FileOpen(path, fmOpenRead or fmShareDenyNone);
  if h = THandle(-1) then raise Exception.Create('cannot open ' + path);
  try
    if FileSeek(h, off, fsFromBeginning) < 0 then Exit;
    SetLength(buf, len);
    tot := 0;
    while tot < len do begin
      want := len - tot;
      if want > $40000000 then want := $40000000;
      got := FileRead(h, buf[tot], want);
      if got <= 0 then Break;
      Inc(tot, got);
    end;
    if tot < len then SetLength(buf, tot);
    Result := tot;
  finally
    FileClose(h);
  end;
end;

function TViewer.CountNlMem(a, b: Int64): Int64;
var
  i: Int64;
begin
  Result := 0;
  if b > Length(data) then b := Length(data);
  for i := a to b - 1 do
    if data[i] = 10 then Inc(Result);
end;

function TViewer.CountNlFile(a, b: Int64): Int64;
var
  h: THandle;
  buf: TByteArr;
  left, want, got: Int64;
  i: Integer;
begin
  Result := 0;
  h := FileOpen(path, fmOpenRead or fmShareDenyNone);
  if h = THandle(-1) then Exit;
  try
    if FileSeek(h, a, fsFromBeginning) < 0 then Exit;
    SetLength(buf, 1 shl 20);
    left := b - a;
    while left > 0 do begin
      want := left;
      if want > Length(buf) then want := Length(buf);
      got := FileRead(h, buf[0], want);
      if got <= 0 then Break;
      for i := 0 to got - 1 do
        if buf[i] = 10 then Inc(Result);
      Dec(left, got);
    end;
  finally
    FileClose(h);
  end;
end;

procedure TViewer.AddAnchor(off, nl: Int64);
var
  i: Integer;
begin
  for i := 0 to High(anchors) do
    if anchors[i].off = off then Exit;
  if Length(anchors) >= 64 then begin
    Move(anchors[2], anchors[1], (Length(anchors) - 2) * SizeOf(TAnchor));
    SetLength(anchors, Length(anchors) - 1);
  end;
  SetLength(anchors, Length(anchors) + 1);
  anchors[High(anchors)].off := off;
  anchors[High(anchors)].nl := nl;
end;

{ Number of newlines before file offset `off`, counted from the nearest known anchor. }
function TViewer.NlBefore(off: Int64): Int64;
var
  i, best: Integer;
  dist, bd: Int64;
begin
  best := 0;
  bd := High(Int64);
  for i := 0 to High(anchors) do begin
    dist := Abs(anchors[i].off - off);
    if dist < bd then begin bd := dist; best := i; end;
  end;
  if anchors[best].off <= off then
    Result := anchors[best].nl + CountNlFile(anchors[best].off, off)
  else
    Result := anchors[best].nl - CountNlFile(off, anchors[best].off);
  AddAnchor(off, Result);
end;

{ (Re)fill the memory buffer so it is centred on file offset `center`. In text mode the buffer
  starts and ends on line boundaries. }
procedure TViewer.Load(center: Int64);
var
  lim, start, rs, b, oldEnd, newLb, endLb: Int64;
  d: TByteArr;
  p, i, cnt, k: Integer;
  haveLb: Boolean;

  procedure DeleteFront(n: Integer);
  begin
    if n >= Length(d) then SetLength(d, 0)
    else begin
      Move(d[n], d[0], Length(d) - n);
      SetLength(d, Length(d) - n);
    end;
  end;
begin
  lim := limit;
  if fileLen <= lim then begin
    b := 0;
    ReadAt(0, fileLen, d);
  end else begin
    start := center - lim div 2;
    if start < 0 then start := 0;
    if start > fileLen - lim then start := fileLen - lim;
    if hex then begin
      start := start and (not Int64(15));
      b := start;
      ReadAt(start, lim, d);
    end else begin
      rs := start;
      if rs > 0 then Dec(rs);
      ReadAt(rs, lim + (start - rs), d);
      b := start;
      if (start > 0) and (Length(d) > 0) then begin
        { d[0] is the byte just before `start` }
        if d[0] = 10 then DeleteFront(1)
        else begin
          p := -1;
          for i := 0 to High(d) do if d[i] = 10 then begin p := i; Break; end;
          if p >= 0 then begin DeleteFront(p + 1); b := rs + p + 1; end
          else DeleteFront(1);
        end;
      end;
      if b + Length(d) < fileLen then begin
        p := -1;
        for i := High(d) downto 0 do if d[i] = 10 then begin p := i; Break; end;
        if p >= 0 then SetLength(d, p + 1);
      end;
      if Length(d) = 0 then begin
        b := start;
        ReadAt(start, lim, d);
      end;
    end;
  end;

  { Line number bookkeeping: when the new window starts inside the old one, the newlines before
    it are known from memory alone; otherwise count only the gap from a known point. }
  oldEnd := base + Length(data);
  haveLb := True;
  newLb := 0;
  if b = 0 then newLb := 0
  else if hex then haveLb := False
  else if lbValid and (b >= base) and (b <= oldEnd) then
    newLb := lineBase + CountNlMem(0, b - base)
  else begin
    if lbValid then begin
      endLb := lineBase + CountNlMem(0, Length(data));
      AddAnchor(base, lineBase);
      AddAnchor(oldEnd, endLb);
    end;
    newLb := NlBefore(b);
  end;

  { index the line starts }
  cnt := 0;
  if Length(d) > 0 then begin
    cnt := 1;
    for i := 0 to Length(d) - 2 do if d[i] = 10 then Inc(cnt);
  end;
  SetLength(starts, cnt);
  if cnt > 0 then begin
    starts[0] := 0;
    k := 1;
    for i := 0 to Length(d) - 2 do
      if d[i] = 10 then begin starts[k] := i + 1; Inc(k); end;
  end;
  data := d;
  base := b;
  if haveLb then begin lineBase := newLb; lbValid := True; end
  else lbValid := False;
end;

function TViewer.Windowed: Boolean;
begin
  Result := fileLen > Length(data);
end;

function TViewer.AtEnd: Boolean;
begin
  Result := base + Length(data) >= fileLen;
end;

function TViewer.InBuf(abs: Int64): Boolean;
begin
  Result := (abs >= base) and (abs < base + Length(data));
end;

function TViewer.Rel(abs: Int64): Int64;
begin
  Result := abs - base;
  if Result < 0 then Result := 0;
end;

function TViewer.NLines: Integer;
begin
  Result := Length(starts);
end;

function TViewer.NRowsHex: Integer;
begin
  Result := (Length(data) + 15) div 16;
end;

function TViewer.Total: Integer;
begin
  if hex then Result := NRowsHex else Result := NLines;
end;

function TViewer.CurTopOff: Int64;
begin
  if hex then Result := base + Int64(top) * 16
  else if (top >= 0) and (top < Length(starts)) then Result := base + starts[top]
  else Result := base;
end;

{ Reload the buffer centred on `abs` and put the line/row containing it on top. }
procedure TViewer.Recenter(abs: Int64);
var
  r: Int64;
begin
  try
    Load(abs);
  except
    Exit;
  end;
  r := Rel(abs);
  if hex then top := r div 16 else top := LineOf(r);
  sub := 0;
end;

procedure TViewer.SetLimit(ALimit: Int64);
begin
  limit := ALimit;
  if limit < MIN_LIMIT then limit := MIN_LIMIT;
  if path <> '' then Recenter(CurTopOff);
end;

{ Reload the buffer if the screen has come close to either edge of it. }
function TViewer.MaybeReload: Boolean;
var
  margin, topRel, botRel: Int64;
begin
  Result := False;
  if not Windowed then Exit;
  margin := limit div 8;
  if margin < 16 * 1024 then margin := 16 * 1024;
  if margin > limit div 4 then margin := limit div 4;
  if hex then topRel := Int64(top) * 16
  else if top < Length(starts) then topRel := starts[top]
  else topRel := 0;
  botRel := Rel(botOff);
  if ((base > 0) and (topRel < margin)) or (not AtEnd and (Length(data) - botRel < margin)) then begin
    Recenter(CurTopOff);
    Result := True;
  end;
end;

{ Pick up changes to the file on disk (data appended by a pipe or another program, or a
  truncation). Returns True if the display needs redrawing. }
function TViewer.Refresh(const o: TOpts): Boolean;
var
  sr: TSearchRec;
  len: Int64;
  d, wasAtEnd: Boolean;
  c: Int64;
begin
  Result := False;
  if path = '' then Exit;
  { read the flag before the size so the final bytes are never missed }
  d := (not isStream) or streamDone;
  if FindFirst(path, faAnyFile, sr) <> 0 then Exit;
  len := sr.Size;
  FindClose(sr);
  Result := (len <> fileLen) or (d <> wasDone);
  wasDone := d;
  if len < fileLen then begin
    { truncated or replaced: start over }
    fileLen := len;
    SetLength(anchors, 1);
    anchors[0].off := 0; anchors[0].nl := 0;
    markTop := -1; markBot := -1; lastMatch := -1;
    Recenter(0);
    top := 0;
  end else if len > fileLen then begin
    wasAtEnd := AtEnd;
    fileLen := len;
    if wasAtEnd then begin
      { the buffer reached the old end of file: extend it in place }
      c := CurTopOff;
      Recenter(c);
    end;
    if follow then GoEnd(o);
  end;
end;

function TViewer.LooksBinary: Boolean;
var
  i, n: Integer;
begin
  Result := False;
  n := Length(data);
  if n > 8192 then n := 8192;
  for i := 0 to n - 1 do
    if data[i] = 0 then Exit(True);
end;

{ File offset where line n (0-based) starts; scans the file. }
function TViewer.OffsetOfLine(n: Int64; out exact: Boolean): Int64;
var
  h: THandle;
  buf: TByteArr;
  got, line, pos, lastStart, st: Int64;
  i: Integer;
begin
  exact := False;
  Result := 0;
  if n = 0 then begin exact := True; Exit; end;
  h := FileOpen(path, fmOpenRead or fmShareDenyNone);
  if h = THandle(-1) then Exit;
  try
    SetLength(buf, 1 shl 16);
    line := 0; pos := 0; lastStart := 0;
    repeat
      got := FileRead(h, buf[0], Length(buf));
      if got <= 0 then Break;
      for i := 0 to got - 1 do
        if buf[i] = 10 then begin
          Inc(line);
          st := pos + i + 1;
          if st < fileLen then lastStart := st;
          if line = n then begin
            if st < fileLen then begin Result := st; exact := True; end
            else Result := lastStart;
            Exit;
          end;
        end;
      Inc(pos, got);
    until False;
    Result := lastStart;
  finally
    FileClose(h);
  end;
end;

{ Search the whole file (not just the buffer). Returns the absolute offset of the match. }
function TViewer.Search(const f: TFind; from: Int64; fwd: Boolean; out mpos: Int64; out mlen: Integer): Boolean;
const
  CH = 1 shl 20;
var
  d: TByteArr;
  pos, endp, st, len, i: Int64;
  over: Integer;
begin
  Result := False;
  mpos := -1;
  mlen := 0;
  if f.needle = '' then Exit;
  if not Windowed then begin
    if fwd then i := FindFwd(data, f, from, mlen) else i := FindBack(data, f, from, mlen);
    if i >= 0 then begin mpos := i; Result := True; end;
    Exit;
  end;
  { a regex match that straddles a chunk boundary is found if it is shorter than 4 KB }
  if f.re <> nil then over := 4096 else over := Length(f.needle) - 1;
  if fwd then begin
    pos := from;
    while pos < fileLen do begin
      ReadAt(pos, CH + over, d);
      i := FindFwd(d, f, 0, mlen);
      if i >= 0 then begin mpos := pos + i; Exit(True); end;
      Inc(pos, CH);
    end;
  end else begin
    endp := from;
    if endp > fileLen then endp := fileLen;
    while endp > 0 do begin
      st := endp - CH;
      if st < 0 then st := 0;
      len := endp - st + over;
      if len > fileLen - st then len := fileLen - st;
      ReadAt(st, len, d);
      i := FindBack(d, f, endp - st, mlen);
      if i >= 0 then begin mpos := st + i; Exit(True); end;
      endp := st;
    end;
  end;
end;

{ ---------------------------------------------------------------- line helpers }

procedure TViewer.LineContent(i: Integer; out s, e: Int64);
begin
  s := starts[i];
  e := LineEndFull(i);
  if (e > s) and (data[e - 1] = 10) then Dec(e);
  if (e > s) and (data[e - 1] = 13) then Dec(e);
end;

function TViewer.LineEndFull(i: Integer): Int64;
begin
  if i + 1 < Length(starts) then Result := starts[i + 1] else Result := Length(data);
end;

function TViewer.LineOf(off: Int64): Integer;
var
  lo, hi, mid: Integer;
begin
  Result := 0;
  if Length(starts) = 0 then Exit;
  lo := 0; hi := High(starts);
  while lo < hi do begin
    mid := (lo + hi + 1) div 2;
    if starts[mid] <= off then lo := mid else hi := mid - 1;
  end;
  Result := lo;
end;

procedure TViewer.LineCells(i: Integer; const o: TOpts; var cl: TCellList);
var
  s, e, p: Int64;
  b: Byte;
  k, k2, n0: Integer;
  cp, cp2: Cardinal;
  useUtf8: Boolean;
  prev: TCl;
  pc: Byte;
  nc: Cardinal;

  { decode the character at q (cp, size) without emitting it }
  function Peek(q: Int64; out c: Cardinal): Integer;
  begin
    if useUtf8 and (data[q] >= $C2) then begin
      Result := Utf8Decode(@data[q], e - q, c);
      if Result > 0 then Exit;
    end;
    c := data[q];
    Result := 1;
  end;

begin
  cl.n := 0;
  curFl := 0; curFg := -1; curBg := -1;
  LineContent(i, s, e);
  useUtf8 := utf8 and (o.hibit = 0);
  p := s;
  while p < e do begin
    b := data[p];
    if (b = 27) and o.ansi then begin                       { ANSI colour / attribute sequences }
      Inc(p, EscSeq(data, p, e));
      Continue;
    end;
    if o.ansi and (b = 8) and (cl.n > 0) and (p + 1 < e) then begin
      { backspace overstrike, as written by nroff/man: X BS X is bold, _ BS X is underline }
      k2 := Peek(p + 1, nc);
      if (nc >= 32) and (nc <> 127) then begin
        prev := cl.a[cl.n - 1];
        pc := prev.ch;
        if (nc < 128) and (pc = Byte(nc)) then begin
          cl.a[cl.n - 1].fl := prev.fl or SF_BOLD;
          Inc(p, 1 + k2);
          Continue;
        end else if pc = Ord('_') then begin
          Dec(cl.n);
          n0 := cl.n;
          if nc < 128 then EmitByte(cl, Byte(nc), p + 1, o) else EmitCp(cl, nc, p + 1, o);
          if cl.n = n0 + 1 then begin
            cl.a[n0].fl := cl.a[n0].fl or SF_UL;
            Inc(p, 1 + k2);
            Continue;
          end;
          cl.n := n0 + 1;                       { could not merge; keep the underscore }
          cl.a[n0] := prev;
        end else if nc = Ord('_') then begin
          cl.a[cl.n - 1].fl := prev.fl or SF_UL;
          Inc(p, 1 + k2);
          Continue;
        end;
      end;
    end;
    if useUtf8 and (b >= $C2) then begin
      k := Utf8Decode(@data[p], e - p, cp);
      if k > 0 then begin
        EmitCp(cl, cp, p, o);
        Inc(p, k);
        Continue;
      end;
    end;
    if o.hibit = 1 then b := b and $7F;
    if (o.hibit = 2) and (b >= 128) then b := Ord('.');
    EmitByte(cl, b, p, o);
    Inc(p);
  end;
  curFl := 0; curFg := -1; curBg := -1;
  if isMd and o.md then MdPass(cl, vw);
end;

function TViewer.RowsOf(i: Integer; const o: TOpts): Integer;
var
  cl: TCellList;
begin
  if not o.wrap then Exit(1);
  SetLength(cl.a, 0);
  LineCells(i, o, cl);
  if vw < 1 then vw := 1;
  Result := (cl.n + vw - 1) div vw;
  if Result < 1 then Result := 1;
end;

{ ---------------------------------------------------------------- scrolling }

function TViewer.Remaining(const o: TOpts): Int64;
var
  l, n: Integer;
begin
  if not AtEnd then Exit(High(Int64));
  if hex then Exit(NRowsHex - top);
  if not o.wrap then Exit(NLines - top);
  Result := 0;
  l := top;
  while l < NLines do begin
    n := RowsOf(l, o);
    if l = top then begin if n > sub then Inc(Result, n - sub); end else Inc(Result, n);
    if Result > vh then Break;
    Inc(l);
  end;
end;

function TViewer.EofVisible(const o: TOpts): Boolean;
begin
  Result := Remaining(o) <= vh;
end;

function TViewer.StepDown(const o: TOpts): Boolean;
begin
  if sub + 1 < RowsOf(top, o) then begin Inc(sub); Result := True; end
  else if top + 1 < NLines then begin Inc(top); sub := 0; Result := True; end
  else Result := False;
end;

function TViewer.StepUp(const o: TOpts): Boolean;
begin
  if sub > 0 then begin Dec(sub); Result := True; end
  else if top > 0 then begin Dec(top); sub := RowsOf(top, o) - 1; Result := True; end
  else Result := False;
end;

function TViewer.MaxTop: Integer;
var
  v: Integer;
begin
  v := vh;
  if v < 1 then v := 1;
  if AtEnd then Result := Total - v else Result := Total - 1;
  if Result < 0 then Result := 0;
end;

procedure TViewer.Down(n: Integer; const o: TOpts);
var
  left, step: Int64;
  c: Int64;
  i: Integer;
begin
  if hex or not o.wrap then begin
    left := n;
    repeat
      step := MaxTop - top;
      if step < 0 then step := 0;
      if left < step then step := left;
      Inc(top, step);
      Dec(left, step);
      if (left = 0) or AtEnd then Break;
      c := CurTopOff;
      Recenter(c);
      if MaxTop - top <= 0 then Break;
    until False;
    Exit;
  end;
  for i := 1 to n do
    if EofVisible(o) or not StepDown(o) then Break;
end;

procedure TViewer.Up(n: Integer; const o: TOpts);
var
  left, step: Int64;
  c: Int64;
  i: Integer;
begin
  if hex or not o.wrap then begin
    left := n;
    repeat
      step := top;
      if left < step then step := left;
      Dec(top, step);
      Dec(left, step);
      if (left = 0) or (base = 0) then Break;
      c := CurTopOff;
      Recenter(c);
      if top = 0 then Break;
    until False;
    Exit;
  end;
  for i := 1 to n do
    if not StepUp(o) then Break;
end;

procedure TViewer.GoHome;
begin
  if base > 0 then Recenter(0);
  top := 0; sub := 0; col := 0;
end;

procedure TViewer.GoEnd(const o: TOpts);
begin
  if not AtEnd then Recenter(fileLen);
  if hex or not o.wrap then top := MaxTop
  else if NLines > 0 then begin
    top := NLines - 1;
    sub := RowsOf(top, o) - 1;
    if vh > 1 then Up(vh - 1, o);
  end;
end;

{ Show line/row n (0-based) at the top, but never scroll past the end of the file. }
procedure TViewer.GotoRow(n: Integer; const o: TOpts);
var
  r: Int64;
begin
  sub := 0;
  if hex or not o.wrap then begin
    top := n;
    if top > MaxTop then top := MaxTop;
    if top < 0 then top := 0;
  end else if NLines > 0 then begin
    top := n;
    if top > NLines - 1 then top := NLines - 1;
    r := Remaining(o);
    if r < vh then Up(vh - r, o);
  end;
end;

{ Skip to absolute file offset abs. }
procedure TViewer.GotoOff(abs: Int64; const o: TOpts);
var
  r: Int64;
  n: Integer;
begin
  if Windowed and not InBuf(abs) then begin
    Recenter(abs);
    Exit;
  end;
  r := Rel(abs);
  if hex then n := r div 16 else n := LineOf(r);
  GotoRow(n, o);
end;

{ Skip to line n (0-based) of the file; in hex mode, to row n. }
procedure TViewer.GotoLine(n: Int64; const o: TOpts);
var
  off: Int64;
  exact: Boolean;
begin
  if not Windowed then begin
    if n > High(Integer) then n := High(Integer);
    GotoRow(n, o);
    Exit;
  end;
  if hex then off := n * 16
  else begin
    off := OffsetOfLine(n, exact);
    if exact then AddAnchor(off, n);
  end;
  GotoOff(off, o);
end;

procedure TViewer.ToggleHex;
var
  abs: Int64;
  r: Int64;
begin
  abs := CurTopOff;
  hex := not hex;
  sub := 0; col := 0;
  if Windowed then Recenter(abs)
  else begin
    r := Rel(abs);
    if hex then top := r div 16 else top := LineOf(r);
  end;
end;

function TViewer.LineVisible(line: Integer; const o: TOpts): Boolean;
var
  r, l, n: Integer;
begin
  Result := False;
  if line < top then Exit;
  if not o.wrap then Exit(line < top + vh);
  r := 0;
  l := top;
  while (l < NLines) and (r < vh) do begin
    if l = line then Exit(True);
    n := RowsOf(l, o);
    if l = top then begin if n > sub then Inc(r, n - sub); end else Inc(r, n);
    Inc(l);
  end;
end;

{ Scroll so the byte at absolute offset abs is on screen. }
procedure TViewer.Reveal(abs: Int64; const o: TOpts);
var
  off: Int64;
  line, idx, i: Integer;
  cl: TCellList;
begin
  if Windowed and not InBuf(abs) then Recenter(abs);
  off := Rel(abs);
  if hex then begin
    i := off div 16;
    if (i < top) or (i >= top + vh) then GotoRow(i, o);
    Exit;
  end;
  line := LineOf(off);
  if not LineVisible(line, o) then GotoRow(line, o);
  if not o.wrap then begin
    SetLength(cl.a, 0);
    LineCells(line, o, cl);
    idx := 0;
    for i := 0 to cl.n - 1 do
      if cl.a[i].src >= off then begin idx := i; Break; end;
    if (idx < col) or (idx >= col + vw) then begin
      if idx < vw then col := 0 else col := idx - vw div 4;
    end;
  end;
end;

{ ---------------------------------------------------------------- marks }

{ The bytes between the top and bottom marks (read from disk when they are outside the buffer). }
function TViewer.Block(out b: TByteArr): Boolean;
var
  a, e: Int64;
begin
  Result := False;
  SetLength(b, 0);
  a := markTop; e := markBot;
  if (a < 0) or (e < 0) then Exit;
  if e > fileLen then e := fileLen;
  if a >= e then Exit;
  if InBuf(a) and (e <= base + Length(data)) then begin
    SetLength(b, e - a);
    Move(data[a - base], b[0], e - a);
    Exit(True);
  end;
  try
    ReadAt(a, e - a, b);
    Result := Length(b) > 0;
  except
    Result := False;
  end;
end;

function TViewer.Marked(rp: Int64): Boolean;
var
  a: Int64;
begin
  a := base + rp;
  Result := (markTop >= 0) and (markBot >= 0) and (a >= markTop) and (a < markBot);
end;

{ ---------------------------------------------------------------- drawing }

{ Matches inside the buffer range [from, till). }
function TViewer.Matches(const f: TFind; from, till: Int64): TMatchArr;
var
  p, m: Int64;
  n, q: Integer;
  s: RawByteString;
begin
  SetLength(Result, 0);
  if f.re <> nil then begin
    { a regex is applied to one line at a time, so ^ and $ mean the start and end of the line }
    if till > Length(data) then till := Length(data);
    if till <= from then Exit;
    s := BytesToStr(data, from, till);
    f.re.InputString := s;
    q := 1;
    while q <= Length(s) do begin
      if not f.re.ExecPos(q) then Break;
      if f.re.MatchLen[0] > 0 then begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)].start := from + f.re.MatchPos[0] - 1;
        Result[High(Result)].len := f.re.MatchLen[0];
        q := f.re.MatchPos[0] + f.re.MatchLen[0];
      end else
        q := f.re.MatchPos[0] + 1;
    end;
    Exit;
  end;
  n := Length(f.needle);
  p := from - (n - 1);
  if p < 0 then p := 0;
  repeat
    m := FindFwd(data, f, p, n);
    if (m < 0) or (m >= till) then Break;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].start := m;
    Result[High(Result)].len := n;
    p := m + 1;
  until False;
end;

procedure TViewer.Render(y0, h, w: Integer; const o: TOpts; f: PFind; active: Boolean);
begin
  RenderInner(y0, h, w, o, f, active);
  if MaybeReload then RenderInner(y0, h, w, o, f, active);
end;

procedure TViewer.RenderInner(y0, h, w: Integer; const o: TOpts; f: PFind; active: Boolean);
var
  ruler: Boolean;
  content, y, x, n, sf, sb, pct, tlen, plen: Integer;
  nm, s, a, b, p: string;
begin
  ruler := o.ruler and not hex and (h > 3);
  content := h - 1;
  if content < 0 then content := 0;
  vw := w;
  vh := content;
  if ruler then Dec(vh);
  if vh < 1 then vh := 1;
  { keep the view legal after resizes / option changes }
  if hex or not o.wrap then begin
    sub := 0;
    if top > MaxTop then top := MaxTop;
  end else if NLines > 0 then begin
    if top > NLines - 1 then top := NLines - 1;
    n := RowsOf(top, o);
    if sub > n - 1 then sub := n - 1;
  end;
  for y := y0 + 1 to y0 + h - 1 do ScrFill(0, y, w, 32, o.textFg, o.textBg);
  y := y0 + 1;
  if ruler then begin
    for x := 0 to w - 1 do begin
      n := col + x + 1;
      if n mod 10 = 0 then ScrPut(x, y, Ord('0') + (n div 10) mod 10, 11, o.textBg)
      else if n mod 5 = 0 then ScrPut(x, y, Ord('+'), 11, o.textBg)
      else ScrPut(x, y, $C4, 11, o.textBg);
    end;
    Inc(y);
  end;
  if hex then RenderHex(y, w, o, f) else RenderText(y, w, o, f);

  { top status line }
  if active then begin sf := o.statFg; sb := o.statBg; end else begin sf := 15; sb := 7; end;
  ScrFill(0, y0, w, 32, sf, sb);
  if path = '' then nm := '(no file)' else nm := name;
  a := IntToStr(first);
  if byOffset then b := '@' + IntToStr(last) else b := IntToStr(last);
  plen := Utf8Len(b);
  if plen < 6 then plen := 6;
  s := PadR('LIST', 4) + PadL(a, 11) + PadL(b, plen + 1) + '     ' + mtime + ' • ' + nm;
  ScrPutsN(0, y0, s, w, sf, sb);
  if fileLen = 0 then pct := 100 else pct := botOff * 100 div fileLen;
  if pct > 100 then pct := 100;
  p := IntToStr(pct) + '%';
  { when scrolled sideways, say which column the display starts at }
  if (not hex) and (not o.wrap) and (col > 0) then p := 'Col ' + IntToStr(col + 1) + '  ' + p;
  tlen := Utf8Len(s);
  plen := Utf8Len(p);
  if w > tlen + plen + 2 then ScrPuts(w - plen - 1, y0, p, sf, sb);
end;

procedure TViewer.RenderText(y0, w: Integer; const o: TOpts; f: PFind);

  { colours for a cell that carries bold / underline / reverse or explicit colours }
  procedure StyleColors(const c: TCl; var fg, bg: Byte);
  var
    t: Byte;
  begin
    if c.fg >= 0 then fg := c.fg;
    if c.bg >= 0 then bg := c.bg;
    if (c.fl and (SF_BOLD or SF_UL)) <> 0 then begin
      if c.fg >= 0 then begin
        if (c.fl and SF_BOLD) <> 0 then fg := fg or 8;
      end else if (c.fl and SF_BOLD) = 0 then fg := UL_FG
      else if (c.fl and SF_UL) = 0 then fg := BOLD_FG
      else fg := BOLDUL_FG;
    end;
    if (c.fl and SF_REV) <> 0 then begin
      t := fg and 7; fg := bg; bg := t;
    end;
  end;

var
  n, line, sub0, row, lastLine, nrows, from, x, y, i: Integer;
  cl: TCellList;
  ls, le: Int64;
  isMarked, hl: Boolean;
  ms: TMatchArr;
  tf, tb, fg, bg: Byte;
  c: TCl;
begin
  n := NLines;
  line := top; sub0 := sub; row := 0; lastLine := top;
  maxW := 0;
  SetLength(cl.a, 256);
  while (row < vh) and (line < n) do begin
    LineCells(line, o, cl);
    if cl.n > maxW then maxW := cl.n;
    LineContent(line, ls, le);
    isMarked := Marked(starts[line]);
    if f <> nil then ms := Matches(f^, ls, le) else SetLength(ms, 0);
    if o.wrap then begin
      nrows := (cl.n + w - 1) div w;
      if nrows < 1 then nrows := 1;
    end else nrows := 1;
    while (sub0 < nrows) and (row < vh) do begin
      y := y0 + row;
      if o.wrap then from := sub0 * w else from := col;
      if isMarked then begin tf := o.textBg; tb := o.textFg; end else begin tf := o.textFg; tb := o.textBg; end;
      if isMarked then ScrFill(0, y, w, 32, tf, tb);
      for x := 0 to w - 1 do begin
        if from + x >= cl.n then Break;
        c := cl.a[from + x];
        hl := False;
        for i := 0 to High(ms) do
          if (c.src >= ms[i].start) and (c.src < ms[i].start + ms[i].len) then begin hl := True; Break; end;
        if hl then begin fg := o.findFg; bg := o.findBg; end else begin
          fg := tf; bg := tb;
          if (c.fl <> 0) or (c.fg >= 0) or (c.bg >= 0) then StyleColors(c, fg, bg);
        end;
        ScrPut(x, y, c.ch, fg, bg);
      end;
      Inc(row);
      Inc(sub0);
    end;
    lastLine := line;
    if sub0 >= nrows then begin Inc(line); sub0 := 0; end else Break;
  end;
  atEof := (line >= n) and AtEnd;
  byOffset := Windowed;
  if byOffset then begin
    first := lineBase + top + 1;
    if n = 0 then last := base else last := base + starts[lastLine];
  end else begin
    if n = 0 then first := 0 else first := top + 1;
    if n = 0 then last := 0 else last := lastLine + 1;
  end;
  if n = 0 then botOff := base else botOff := base + LineEndFull(lastLine);
end;

procedure TViewer.RenderHex(y0, w: Integer; const o: TOpts; f: PFind);
var
  rows, len, e, r, y, j, i, k: Integer;
  off, absOff: Int64;
  b: Byte;
  ms: TMatchArr;
  fg, bg, afg, abg: Byte;
  hx, lab: string;
  hl: Boolean;
begin
  rows := NRowsHex;
  len := Length(data);
  e := top + vh;
  if e > rows then e := rows;
  for r := top to e - 1 do begin
    y := y0 + r - top;
    off := Int64(r) * 16;
    if (f <> nil) and (f^.re <> nil) then begin
      { a regex can't be matched row by row, so only the last hit is highlighted }
      SetLength(ms, 0);
      if (lastMatch >= 0) and (lastMatch + lastLen > base + off) and (lastMatch < base + off + 16) then begin
        SetLength(ms, 1);
        ms[0].start := lastMatch - base;
        ms[0].len := lastLen;
      end;
    end else if f <> nil then ms := Matches(f^, off, off + 16) else SetLength(ms, 0);
    absOff := base + off;
    if fileLen > $FFFFFF then lab := IntToHex(absOff, 8) else lab := IntToHex(absOff, 6);
    ScrPuts(0, y, lab, o.textFg, o.textBg);
    for j := 0 to 15 do begin
      i := off + j;
      if i >= len then Break;
      b := data[i];
      if Marked(i) then begin fg := o.textBg; bg := o.textFg; end else begin fg := o.textFg; bg := o.textBg; end;
      hl := False;
      for k := 0 to High(ms) do
        if (i >= ms[k].start) and (i < ms[k].start + ms[k].len) then begin hl := True; Break; end;
      if hl then begin fg := o.findFg; bg := o.findBg; end;
      hx := IntToHex(b, 2);
      ScrPuts(HEX_X + j * 3, y, hx, fg, bg);
      if j = 7 then ScrPut(HEX_X + j * 3 + 2, y, Ord('-'), o.textFg, o.textBg);
      { ASCII column: control characters are drawn inverse, as in the DOS original }
      afg := fg; abg := bg;
      if ((b < 32) or (b = 127)) and (fg = o.textFg) and (bg = o.textBg) then begin afg := o.textBg; abg := o.textFg; end;
      if b = 0 then ScrPut(ASC_X + j, y, 32, afg, abg) else ScrPut(ASC_X + j, y, b, afg, abg);
    end;
  end;
  atEof := (top + vh >= rows) and AtEnd;
  byOffset := False;
  if rows = 0 then first := 0 else first := base div 16 + top + 1;
  if rows = 0 then last := 0 else last := base div 16 + e;
  if rows = 0 then botOff := base else begin
    i := e * 16;
    if i > len then i := len;
    botOff := base + i;
  end;
  maxW := 0;
end;

end.
