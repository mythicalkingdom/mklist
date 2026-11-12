unit uOpts;
{$mode objfpc}{$H+}
{ User options (toggles and colours) and their persistence (Alt-C "Save options"). }

interface

uses SysUtils, Classes;

const
  MIN_MEM = 64 * 1024;

type
  TOpts = record
    wrap, tabs, ruler, junk: Boolean;
    hibit: Integer;                       { 0 = show all (8), 1 = strip high bit (7), 2 = filter (*) }
    keyAhead, preload, saver, sharing, printer: Boolean;
    textFg, textBg, statFg, statBg, findFg, findBg: Byte;
    maxMem: Int64;                        { maximum bytes of a file kept in memory }
    remember: Boolean;                    { remember the last position in each file }
  end;

procedure OptsDefault(var o: TOpts);
function ConfigDir: string;
procedure OptsLoad(var o: TOpts);
function OptsSave(const o: TOpts): string;
function ParseSize(const s: string; out n: Int64): Boolean;
function FmtSize(n: Int64): string;

implementation

procedure OptsDefault(var o: TOpts);
begin
  o.wrap := False; o.tabs := True; o.ruler := False; o.junk := False; o.hibit := 0;
  o.keyAhead := True; o.preload := True; o.saver := False; o.sharing := True; o.printer := False;
  o.textFg := 15; o.textBg := 1; o.statFg := 0; o.statBg := 3; o.findFg := 0; o.findBg := 6;
  o.maxMem := 1 shl 20;
  o.remember := True;
end;

function ConfigDir: string;
var
  b: string;
begin
  {$IFDEF WINDOWS}
  b := GetEnvironmentVariable('APPDATA');
  {$ELSE}
  b := GetEnvironmentVariable('XDG_CONFIG_HOME');
  if (b = '') and (GetEnvironmentVariable('HOME') <> '') then
    b := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) + '.config';
  {$ENDIF}
  if b = '' then Exit('');
  Result := IncludeTrailingPathDelimiter(b) + 'list';
end;

function CfgPath: string;
begin
  Result := ConfigDir;
  if Result <> '' then Result := IncludeTrailingPathDelimiter(Result) + 'list.cfg';
end;

procedure OptsLoad(var o: TOpts);
var
  sl: TStringList;
  i, p, n: Integer;
  k, v: string;
  b: Boolean;
  big: Int64;
begin
  if CfgPath = '' then Exit;
  if not FileExists(CfgPath) then Exit;
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile(CfgPath);
    except
      Exit;
    end;
    for i := 0 to sl.Count - 1 do begin
      p := Pos('=', sl[i]);
      if p = 0 then Continue;
      k := Trim(Copy(sl[i], 1, p - 1));
      v := Trim(Copy(sl[i], p + 1, MaxInt));
      b := v = '1';
      n := StrToIntDef(v, 0);
      if k = 'wrap' then o.wrap := b
      else if k = 'tabs' then o.tabs := b
      else if k = 'ruler' then o.ruler := b
      else if k = 'junk' then o.junk := b
      else if k = 'hibit' then begin if n > 2 then n := 2; if n < 0 then n := 0; o.hibit := n end
      else if k = 'key_ahead' then o.keyAhead := b
      else if k = 'preload' then o.preload := b
      else if k = 'saver' then o.saver := b
      else if k = 'sharing' then o.sharing := b
      else if k = 'printer' then o.printer := b
      else if k = 'remember' then o.remember := b
      { this video mode has only 8 background colours, so backgrounds are masked to 0..7 }
      else if k = 'text_fg' then o.textFg := n and 15
      else if k = 'text_bg' then o.textBg := n and 7
      else if k = 'stat_fg' then o.statFg := n and 15
      else if k = 'stat_bg' then o.statBg := n and 7
      else if k = 'find_fg' then o.findFg := n and 15
      else if k = 'find_bg' then o.findBg := n and 7
      else if k = 'max_mem' then begin
        big := StrToInt64Def(v, o.maxMem);
        if big < MIN_MEM then big := MIN_MEM;
        o.maxMem := big;
      end;
    end;
  finally
    sl.Free;
  end;
end;

function OptsSave(const o: TOpts): string;
var
  sl: TStringList;
  function B(x: Boolean): string;
  begin
    if x then Result := '1' else Result := '0';
  end;
begin
  Result := CfgPath;
  if Result = '' then raise Exception.Create('no config directory');
  ForceDirectories(ConfigDir);
  sl := TStringList.Create;
  try
    sl.Add('wrap=' + B(o.wrap)); sl.Add('tabs=' + B(o.tabs)); sl.Add('ruler=' + B(o.ruler));
    sl.Add('junk=' + B(o.junk)); sl.Add('hibit=' + IntToStr(o.hibit));
    sl.Add('key_ahead=' + B(o.keyAhead)); sl.Add('preload=' + B(o.preload));
    sl.Add('saver=' + B(o.saver)); sl.Add('sharing=' + B(o.sharing)); sl.Add('printer=' + B(o.printer));
    sl.Add('text_fg=' + IntToStr(o.textFg)); sl.Add('text_bg=' + IntToStr(o.textBg));
    sl.Add('stat_fg=' + IntToStr(o.statFg)); sl.Add('stat_bg=' + IntToStr(o.statBg));
    sl.Add('find_fg=' + IntToStr(o.findFg)); sl.Add('find_bg=' + IntToStr(o.findBg));
    sl.Add('max_mem=' + IntToStr(o.maxMem)); sl.Add('remember=' + B(o.remember));
    sl.SaveToFile(Result);
  finally
    sl.Free;
  end;
end;

{ Parse a size such as 512K, 1M, 2G or a plain byte count. }
function ParseSize(const s: string; out n: Int64): Boolean;
var
  t: string;
  mult: Int64;
  d: Double;
  code: Integer;
begin
  Result := False;
  t := LowerCase(Trim(s));
  if (t <> '') and (t[Length(t)] = 'b') then Delete(t, Length(t), 1);
  if t = '' then Exit;
  mult := 1;
  case t[Length(t)] of
    'k': mult := 1 shl 10;
    'm': mult := 1 shl 20;
    'g': mult := 1 shl 30;
  end;
  if mult > 1 then Delete(t, Length(t), 1);
  Val(Trim(t), d, code);
  if (code <> 0) or (d <= 0) then Exit;
  n := Trunc(d * mult);
  if n < MIN_MEM then n := MIN_MEM;
  Result := True;
end;

function FmtSize(n: Int64): string;
begin
  if (n >= (Int64(1) shl 30)) and (n mod (Int64(1) shl 30) = 0) then Result := IntToStr(n shr 30) + 'G'
  else if (n >= (1 shl 20)) and (n mod (1 shl 20) = 0) then Result := IntToStr(n shr 20) + 'M'
  else if (n >= (1 shl 10)) and (n mod (1 shl 10) = 0) then Result := IntToStr(n shr 10) + 'K'
  else Result := IntToStr(n) + ' bytes';
end;

end.
