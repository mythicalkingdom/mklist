unit uSpool;
{$mode objfpc}{$H+}
{ Standard input support. Piped input is copied into a temporary file which the viewer then treats
  like any other (seekable, windowed) file that happens to be growing. There are no threads: the
  main loop calls Pump, which reads whatever is available without blocking.
  On Unix, file descriptor 0 is re-pointed at /dev/tty so the Keyboard unit still sees the terminal.
  (The Windows branch is untested.) }

interface

uses SysUtils {$IFDEF UNIX}, BaseUnix {$ENDIF} {$IFDEF WINDOWS}, Windows {$ENDIF};

type
  TSpool = class
  public
    path: string;
    done: Boolean;
    constructor Create;
    function Pump: Boolean;     { True if the spool file grew or the input ended }
    procedure Cleanup;
  private
    outH: THandle;
    {$IFDEF UNIX}
    fd: cint;
    {$ENDIF}
    {$IFDEF WINDOWS}
    inH: THandle;
    {$ENDIF}
    buf: array[0..65535] of Byte;
    procedure Append(n: Integer);
  end;

implementation

constructor TSpool.Create;
{$IFDEF UNIX}
var
  tty: cint;
{$ENDIF}
{$IFDEF WINDOWS}
var
  conin: THandle;
{$ENDIF}
begin
  inherited Create;
  done := False;
  path := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'list-' + IntToStr(GetProcessID) + '-' +
          IntToStr(GetTickCount64) + '.tmp';
  outH := FileCreate(path);
  if outH = THandle(-1) then raise Exception.Create('cannot create ' + path);
  {$IFDEF UNIX}
  fpChmod(path, &600);
  fd := fpDup(0);
  tty := fpOpen('/dev/tty', O_RDWR);
  if tty >= 0 then begin
    fpDup2(tty, 0);
    fpClose(tty);
  end;
  fpFcntl(fd, F_SETFL, fpFcntl(fd, F_GETFL) or O_NONBLOCK);
  {$ENDIF}
  {$IFDEF WINDOWS}
  inH := GetStdHandle(STD_INPUT_HANDLE);
  conin := CreateFile('CONIN$', GENERIC_READ or GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE,
                      nil, OPEN_EXISTING, 0, 0);
  if conin <> INVALID_HANDLE_VALUE then begin
    SetStdHandle(STD_INPUT_HANDLE, conin);
    StdInputHandle := conin;
  end;
  {$ENDIF}
end;

procedure TSpool.Append(n: Integer);
begin
  FileWrite(outH, buf[0], n);
end;

function TSpool.Pump: Boolean;
var
  i, n: Integer;
  {$IFDEF WINDOWS}
  avail, got: DWORD;
  {$ENDIF}
begin
  Result := False;
  if done then Exit;
  for i := 1 to 16 do begin
    {$IFDEF UNIX}
    n := fpRead(fd, buf, SizeOf(buf));
    if n > 0 then begin Append(n); Result := True; end
    else if n = 0 then begin done := True; Result := True; Break; end
    else begin
      if fpGetErrno <> ESysEAGAIN then begin done := True; Result := True; end;
      Break;
    end;
    {$ENDIF}
    {$IFDEF WINDOWS}
    avail := 0;
    if not PeekNamedPipe(inH, nil, 0, nil, @avail, nil) then begin done := True; Result := True; Break; end;
    if avail = 0 then Break;
    if avail > SizeOf(buf) then avail := SizeOf(buf);
    if (not ReadFile(inH, buf, avail, got, nil)) or (got = 0) then begin done := True; Result := True; Break; end;
    Append(got);
    Result := True;
    {$ENDIF}
  end;
  if Result then begin
    {$IFDEF UNIX}
    FileFlush(outH);
    {$ENDIF}
  end;
end;

procedure TSpool.Cleanup;
begin
  FileClose(outH);
  DeleteFile(path);
end;

end.
