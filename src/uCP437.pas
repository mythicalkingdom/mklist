unit uCP437;
{$mode objfpc}{$H+}
{$POINTERMATH ON}
{ IBM PC code page 437 <-> Unicode.  The Video unit's cells hold CP437 bytes, so text that is
  UTF-8 in a file is mapped to CP437 bytes for display (characters outside CP437 show as '?'). }

interface

const
  Cp437Uni: array[0..255] of Word = (
    $0020, $263A, $263B, $2665, $2666, $2663, $2660, $2022,
    $25D8, $25CB, $25D9, $2642, $2640, $266A, $266B, $263C,
    $25BA, $25C4, $2195, $203C, $00B6, $00A7, $25AC, $21A8,
    $2191, $2193, $2192, $2190, $221F, $2194, $25B2, $25BC,
    $0020, $0021, $0022, $0023, $0024, $0025, $0026, $0027,
    $0028, $0029, $002A, $002B, $002C, $002D, $002E, $002F,
    $0030, $0031, $0032, $0033, $0034, $0035, $0036, $0037,
    $0038, $0039, $003A, $003B, $003C, $003D, $003E, $003F,
    $0040, $0041, $0042, $0043, $0044, $0045, $0046, $0047,
    $0048, $0049, $004A, $004B, $004C, $004D, $004E, $004F,
    $0050, $0051, $0052, $0053, $0054, $0055, $0056, $0057,
    $0058, $0059, $005A, $005B, $005C, $005D, $005E, $005F,
    $0060, $0061, $0062, $0063, $0064, $0065, $0066, $0067,
    $0068, $0069, $006A, $006B, $006C, $006D, $006E, $006F,
    $0070, $0071, $0072, $0073, $0074, $0075, $0076, $0077,
    $0078, $0079, $007A, $007B, $007C, $007D, $007E, $2302,
    $00C7, $00FC, $00E9, $00E2, $00E4, $00E0, $00E5, $00E7,
    $00EA, $00EB, $00E8, $00EF, $00EE, $00EC, $00C4, $00C5,
    $00C9, $00E6, $00C6, $00F4, $00F6, $00F2, $00FB, $00F9,
    $00FF, $00D6, $00DC, $00A2, $00A3, $00A5, $20A7, $0192,
    $00E1, $00ED, $00F3, $00FA, $00F1, $00D1, $00AA, $00BA,
    $00BF, $2310, $00AC, $00BD, $00BC, $00A1, $00AB, $00BB,
    $2591, $2592, $2593, $2502, $2524, $2561, $2562, $2556,
    $2555, $2563, $2551, $2557, $255D, $255C, $255B, $2510,
    $2514, $2534, $252C, $251C, $2500, $253C, $255E, $255F,
    $255A, $2554, $2569, $2566, $2560, $2550, $256C, $2567,
    $2568, $2564, $2565, $2559, $2558, $2552, $2553, $256B,
    $256A, $2518, $250C, $2588, $2584, $258C, $2590, $2580,
    $03B1, $00DF, $0393, $03C0, $03A3, $03C3, $00B5, $03C4,
    $03A6, $0398, $03A9, $03B4, $221E, $03C6, $03B5, $2229,
    $2261, $00B1, $2265, $2264, $2320, $2321, $00F7, $2248,
    $00B0, $2219, $00B7, $221A, $207F, $00B2, $25A0, $0020
  );

{ Decode one UTF-8 sequence from p (avail bytes). Returns its length, or 0 if invalid. }
function Utf8Decode(p: PByte; avail: Int64; out cp: Cardinal): Integer;
{ CP437 byte for a Unicode code point, or -1 if there is none. }
function UniToCp437(cp: Cardinal): Integer;
function IsZeroWidth(cp: Cardinal): Boolean;
{ Number of characters (not bytes) in a UTF-8 string. }
function Utf8Len(const s: string): Integer;

implementation

var
  Rev: array[0..65535] of Byte;

function Utf8Decode(p: PByte; avail: Int64; out cp: Cardinal): Integer;
var
  b: Byte;
begin
  Result := 0;
  cp := 0;
  if avail < 1 then Exit;
  b := p[0];
  if b < $80 then begin cp := b; Exit(1); end;
  if (b < $C2) then Exit;
  if b < $E0 then begin
    if (avail < 2) or ((p[1] and $C0) <> $80) then Exit;
    cp := ((b and $1F) shl 6) or (p[1] and $3F);
    Exit(2);
  end;
  if b < $F0 then begin
    if (avail < 3) or ((p[1] and $C0) <> $80) or ((p[2] and $C0) <> $80) then Exit;
    cp := ((b and $0F) shl 12) or ((p[1] and $3F) shl 6) or (p[2] and $3F);
    if (cp < $800) or ((cp >= $D800) and (cp <= $DFFF)) then Exit(0);
    Exit(3);
  end;
  if b < $F5 then begin
    if (avail < 4) or ((p[1] and $C0) <> $80) or ((p[2] and $C0) <> $80) or ((p[3] and $C0) <> $80) then Exit;
    cp := ((b and $07) shl 18) or ((p[1] and $3F) shl 12) or ((p[2] and $3F) shl 6) or (p[3] and $3F);
    if (cp < $10000) or (cp > $10FFFF) then Exit(0);
    Exit(4);
  end;
end;

function UniToCp437(cp: Cardinal): Integer;
begin
  if cp > 65535 then Exit(-1);
  if Rev[cp] = 0 then Exit(-1);
  Result := Rev[cp];
end;

function IsZeroWidth(cp: Cardinal): Boolean;
begin
  Result := ((cp >= $0300) and (cp <= $036F)) or ((cp >= $200B) and (cp <= $200F)) or
            ((cp >= $2060) and (cp <= $2064)) or ((cp >= $FE00) and (cp <= $FE0F)) or (cp = $FEFF);
end;

function Utf8Len(const s: string): Integer;
var
  i, k: Integer;
  cp: Cardinal;
begin
  Result := 0;
  i := 1;
  while i <= Length(s) do begin
    k := Utf8Decode(@s[i], Length(s) - i + 1, cp);
    if k = 0 then k := 1;
    Inc(i, k);
    Inc(Result);
  end;
end;

var
  i: Integer;
initialization
  FillChar(Rev, SizeOf(Rev), 0);
  for i := 255 downto 1 do
    if Cp437Uni[i] <> 0 then Rev[Cp437Uni[i]] := i;
  for i := 32 to 126 do Rev[i] := i;
  Rev[$00A0] := 32;
end.
