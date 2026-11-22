unit uKeys;
{$mode objfpc}{$H+}
{ Keyboard input. On Unix this is our own decoder (non-blocking reads of the terminal, xterm/VT/Linux
  console escape sequences, UTF-8 typed text, and a short timeout so that a lone Esc is delivered as
  Esc). FPC's Keyboard unit, which waits for a second key after Esc and stalls on bursts of more than
  256 bytes, is used elsewhere (Windows); build with -dFORCEKBD to use it on Unix too. }

interface

type
  TKeyKind = (kNone, kChar, kAlt, kF, kUp, kDown, kLeft, kRight, kPgUp, kPgDn, kHome, kEnd,
              kEnter, kEsc, kBack, kDel, kTab, kCtrl);
  TKey = record
    kind: TKeyKind;
    ch: Char;        { kChar: the character (a single byte of a UTF-8 sequence for non-ASCII);
                       kAlt: the lower-case letter; kCtrl: the lower-case letter }
    n: Integer;      { kF: the function key number }
  end;

procedure KeysInit;
procedure KeysDone;
{ Non-blocking: returns True with the next key if one is ready. }
function KeyRead(out k: TKey): Boolean;
{ True if more input is waiting (it may still be an incomplete sequence). }
function KeyPending: Boolean;
{ Discard all pending input. }
procedure KeysFlush;

implementation

uses SysUtils {$IF defined(UNIX) and not defined(FORCEKBD)}, BaseUnix, termio {$ELSE}, Keyboard {$ENDIF};

function LC(c: Char): Char;
begin
  if (c >= 'A') and (c <= 'Z') then Result := Chr(Ord(c) + 32) else Result := c;
end;

{$IF defined(UNIX) and not defined(FORCEKBD)}

const
  BUFSZ = 8192;
  ESC_WAIT_MS = 40;      { how long a lone Esc (or incomplete sequence) waits for more bytes }

type
  TParse = (pNeedMore, pKey, pSkip);

var
  buf: array[0..BUFSZ - 1] of Byte;
  bstart, bend: Integer;
  saved: Termios;
  haveSaved: Boolean = False;
  waitSince: QWord = 0;

procedure KeysInit;
var
  t: Termios;
begin
  bstart := 0; bend := 0; waitSince := 0;
  if TCGetAttr(0, saved) = 0 then begin
    haveSaved := True;
    t := saved;
    CFMakeRaw(t);
    t.c_cc[VMIN] := 0;       { reads return at once with whatever is available }
    t.c_cc[VTIME] := 0;
    TCSetAttr(0, TCSANOW, t);
  end;
end;

procedure KeysDone;
begin
  if haveSaved then TCSetAttr(0, TCSANOW, saved);
end;

procedure Fill;
var
  n: Integer;
begin
  if bstart = bend then begin bstart := 0; bend := 0; end;
  if bend >= BUFSZ then begin
    if bstart = 0 then Exit;
    Move(buf[bstart], buf[0], bend - bstart);
    Dec(bend, bstart);
    bstart := 0;
  end;
  n := fpRead(0, buf[bend], BUFSZ - bend);
  if n > 0 then Inc(bend, n);
end;

{ Examine the bytes at bstart. On pKey, `used` bytes make the key k; on pSkip, `used` bytes are
  an unknown sequence to discard. }
function Parse(out k: TKey; out used: Integer): TParse;
var
  avail, i, np, v: Integer;
  b0, b1, c, fin: Byte;
  params: array[0..3] of Integer;
  haveNum: Boolean;

  function Key(kind: TKeyKind; n: Integer; len: Integer): TParse;
  begin
    k.kind := kind;
    k.n := n;
    used := len;
    Result := pKey;
  end;

begin
  k.kind := kNone; k.ch := #0; k.n := 0; used := 1;
  avail := bend - bstart;
  b0 := buf[bstart];
  if b0 = 27 then begin
    if avail = 1 then Exit(pNeedMore);
    b1 := buf[bstart + 1];
    if b1 = Ord('[') then begin
      if avail = 2 then Exit(pNeedMore);
      c := buf[bstart + 2];
      if c = Ord('[') then begin          { Linux console: ESC [ [ A..E = F1..F5 }
        if avail = 3 then Exit(pNeedMore);
        c := buf[bstart + 3];
        if (c >= Ord('A')) and (c <= Ord('E')) then Exit(Key(kF, c - Ord('A') + 1, 4));
        used := 4;
        Exit(pSkip);
      end;
      np := 0; params[0] := 0; haveNum := False;
      i := 2;
      while i < avail do begin
        c := buf[bstart + i];
        if (c >= Ord('0')) and (c <= Ord('9')) then begin
          if np <= 3 then params[np] := params[np] * 10 + (c - Ord('0'));
          haveNum := True;
        end else if c = Ord(';') then begin
          Inc(np);
          if np <= 3 then params[np] := 0;
          haveNum := True;
        end else if (c >= $40) and (c <= $7E) then begin
          fin := c;
          used := i + 1;
          v := params[0];
          case Chr(fin) of
            'A': Exit(Key(kUp, 0, used));
            'B': Exit(Key(kDown, 0, used));
            'C': Exit(Key(kRight, 0, used));
            'D': Exit(Key(kLeft, 0, used));
            'H': Exit(Key(kHome, 0, used));
            'F': Exit(Key(kEnd, 0, used));
            'Z': Exit(Key(kTab, 0, used));
            'P': Exit(Key(kF, 1, used));
            'Q': Exit(Key(kF, 2, used));
            'R': Exit(Key(kF, 3, used));
            'S': Exit(Key(kF, 4, used));
            '~': begin
              case v of
                1, 7: Exit(Key(kHome, 0, used));
                3: Exit(Key(kDel, 0, used));
                4, 8: Exit(Key(kEnd, 0, used));
                5: Exit(Key(kPgUp, 0, used));
                6: Exit(Key(kPgDn, 0, used));
                11..15: Exit(Key(kF, v - 10, used));
                17..21: Exit(Key(kF, v - 11, used));
              end;
              Exit(pSkip);
            end;
          end;
          Exit(pSkip);        { mouse reports, focus events, unknown keys }
        end else if (c < $20) or (c > $3F) then begin
          { not a valid CSI sequence: treat the ESC as a key of its own }
          Exit(Key(kEsc, 0, 1));
        end;
        Inc(i);
      end;
      if avail > 32 then begin used := avail; Exit(pSkip); end;
      Exit(pNeedMore);
    end;
    if b1 = Ord('O') then begin             { SS3: ESC O P..S = F1..F4, ESC O A..D arrows }
      if avail = 2 then Exit(pNeedMore);
      c := buf[bstart + 2];
      case Chr(c) of
        'P': Exit(Key(kF, 1, 3));
        'Q': Exit(Key(kF, 2, 3));
        'R': Exit(Key(kF, 3, 3));
        'S': Exit(Key(kF, 4, 3));
        'A': Exit(Key(kUp, 0, 3));
        'B': Exit(Key(kDown, 0, 3));
        'C': Exit(Key(kRight, 0, 3));
        'D': Exit(Key(kLeft, 0, 3));
        'H': Exit(Key(kHome, 0, 3));
        'F': Exit(Key(kEnd, 0, 3));
      end;
      { not an SS3 sequence after all: Alt+O followed by something else }
      k.ch := 'o';
      Exit(Key(kAlt, 0, 2));
    end;
    if (b1 >= 33) and (b1 <= 126) then begin  { Alt + a printable key }
      k.ch := LC(Chr(b1));
      Exit(Key(kAlt, 0, 2));
    end;
    Exit(Key(kEsc, 0, 1));                    { ESC ESC, ESC + space/control/UTF-8: a plain Esc }
  end;
  case b0 of
    13, 10: Exit(Key(kEnter, 0, 1));
    9: Exit(Key(kTab, 0, 1));
    8, 127: Exit(Key(kBack, 0, 1));
    1..7, 11, 12, 14..26: begin k.ch := Chr(b0 + 96); Exit(Key(kCtrl, 0, 1)); end;
    32..126, 128..255: begin k.ch := Chr(b0); Exit(Key(kChar, 0, 1)); end;
  end;
  used := 1;
  Result := pSkip;
end;

function KeyRead(out k: TKey): Boolean;
var
  used: Integer;
  r: TParse;
begin
  Result := False;
  k.kind := kNone; k.ch := #0; k.n := 0;
  Fill;
  repeat
    if bstart >= bend then begin waitSince := 0; Exit; end;
    r := Parse(k, used);
    case r of
      pNeedMore: begin
        if waitSince = 0 then waitSince := GetTickCount64;
        if GetTickCount64 - waitSince < ESC_WAIT_MS then Exit;
        { nothing more arrived: a lone Esc is the Esc key, Esc O is Alt+O, anything else is junk }
        waitSince := 0;
        if bend - bstart = 1 then begin
          k.kind := kEsc; Inc(bstart); Exit(True);
        end;
        if (bend - bstart = 2) and (buf[bstart + 1] = Ord('O')) then begin
          k.kind := kAlt; k.ch := 'o'; Inc(bstart, 2); Exit(True);
        end;
        k.kind := kEsc; Inc(bstart); Exit(True);
      end;
      pKey: begin waitSince := 0; Inc(bstart, used); Exit(True); end;
      pSkip: begin waitSince := 0; Inc(bstart, used); end;
    end;
  until False;
end;

function KeyPending: Boolean;
begin
  Fill;
  Result := bstart < bend;
end;

procedure KeysFlush;
begin
  repeat
    Fill;
    if bstart >= bend then Break;
    bstart := bend;
  until False;
  bstart := 0; bend := 0; waitSince := 0;
end;

{$ELSE}

procedure KeysInit;
begin
  InitKeyboard;
end;

procedure KeysDone;
begin
  DoneKeyboard;
end;

function KeyPending: Boolean;
begin
  Result := PollKeyEvent <> 0;
end;

procedure KeysFlush;
begin
  while PollKeyEvent <> 0 do GetKeyEvent;
end;

function UniToUtf8(cp: Cardinal): string;
begin
  if cp < $80 then Result := Chr(cp)
  else if cp < $800 then Result := Chr($C0 or (cp shr 6)) + Chr($80 or (cp and $3F))
  else Result := Chr($E0 or (cp shr 12)) + Chr($80 or ((cp shr 6) and $3F)) + Chr($80 or (cp and $3F));
end;

function KeyRead(out k: TKey): Boolean;
var
  ev, tk: TKeyEvent;
  fl: Byte;
  code: Word;
  c: Char;
  sc: Byte;
begin
  Result := False;
  k.kind := kNone; k.ch := #0; k.n := 0;
  if PollKeyEvent = 0 then Exit;
  ev := GetKeyEvent;
  tk := TranslateKeyEvent(ev);
  fl := GetKeyEventFlags(tk) and 3;
  code := GetKeyEventCode(tk);
  case fl of
    kbFnKey: begin
      if (code >= kbdF1) and (code <= kbdF10) then begin k.kind := kF; k.n := code - kbdF1 + 1; end
      else if code = kbdUp then k.kind := kUp
      else if code = kbdDown then k.kind := kDown
      else if code = kbdLeft then k.kind := kLeft
      else if code = kbdRight then k.kind := kRight
      else if code = kbdPgUp then k.kind := kPgUp
      else if code = kbdPgDn then k.kind := kPgDn
      else if code = kbdHome then k.kind := kHome
      else if code = kbdEnd then k.kind := kEnd
      else if code = kbdDelete then k.kind := kDel;
    end;
    kbPhys: begin
      { an untranslated key: Alt+letter arrives as a DOS scancode with no character }
      sc := (code shr 8) and $FF;
      c := #0;
      case sc of
        $10: c := 'q'; $11: c := 'w'; $12: c := 'e'; $13: c := 'r'; $14: c := 't';
        $15: c := 'y'; $16: c := 'u'; $17: c := 'i'; $18: c := 'o'; $19: c := 'p';
        $1E: c := 'a'; $1F: c := 's'; $20: c := 'd'; $21: c := 'f'; $22: c := 'g';
        $23: c := 'h'; $24: c := 'j'; $25: c := 'k'; $26: c := 'l';
        $2C: c := 'z'; $2D: c := 'x'; $2E: c := 'c'; $2F: c := 'v'; $30: c := 'b';
        $31: c := 'n'; $32: c := 'm';
      end;
      if c <> #0 then begin k.kind := kAlt; k.ch := c; end;
    end;
  else
    if fl = kbUniCode then begin
      { typed text outside ASCII: not representable in a single TKey, so use the first byte }
      c := UniToUtf8(GetKeyEventUniCode(tk))[1];
      k.kind := kChar; k.ch := c;
    end else begin
      c := GetKeyEventChar(tk);
      case Ord(c) of
        13: k.kind := kEnter;
        27: k.kind := kEsc;
        8, 127: k.kind := kBack;
        9: k.kind := kTab;
        1..7, 10..12, 14..26: begin k.kind := kCtrl; k.ch := Chr(Ord(c) + 96); end;
        32..126, 128..255: begin k.kind := kChar; k.ch := c; end;
      end;
    end;
  end;
  Result := k.kind <> kNone;
end;

{$ENDIF}

end.
