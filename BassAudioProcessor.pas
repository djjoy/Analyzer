unit BassAudioProcessor;

interface

uses
  System.SysUtils, System.Classes, windows, QMBeatAnalyzer, bass;

const
  { BASS error codes }
  BASS_OK = 0;
  BASS_ERROR_MEM = 1;
  BASS_ERROR_FILEOPEN = 2;
  BASS_ERROR_DRIVER = 3;
  BASS_ERROR_BUFLOST = 4;
  BASS_ERROR_HANDLE = 5;
  BASS_ERROR_FORMAT = 6;
  BASS_ERROR_POSITION = 7;
  BASS_ERROR_BUSY = 8;
  BASS_ERROR_UNKNOWN = -1;

type
  HSTREAM = THandle;
  DWORD = Cardinal;


  { BASS function signatures }
  TBassInit = function(device: Integer; freq, flags, win: DWORD; clsid: Pointer): Boolean; stdcall;
  TBassFree = function: Boolean; stdcall;
  TBassStreamCreateFile = function(mem: Boolean; const f: PAnsiChar; offset, length: Int64; 
                                   flags: DWORD): HSTREAM; stdcall;
  TBassStreamFree = function(handle: HSTREAM): Boolean; stdcall;
  TBassChannelGetInfo = function(handle: HSTREAM; var info: Integer): Boolean; stdcall;
  TBassChannelGetLength = function(handle: HSTREAM; mode: Integer): Int64; stdcall;
  TBassChannelSetPosition = function(handle: HSTREAM; pos: Int64; mode: Integer): Boolean; stdcall;
  TBassChannelGetPosition = function(handle: HSTREAM; mode: Integer): Int64; stdcall;
  TBassChannelGetData = function(handle: HSTREAM; buffer: Pointer; length: DWORD): DWORD; stdcall;
  TBassErrorGetCode = function: Integer; stdcall;

  TBassAudioProcessor = class
  private
    m_bassHandle: THandle;
    m_stream: HSTREAM;
    m_analyzer: TQMBeatAnalyzer;
    m_sampleBuffer: TArray<Single>;
    m_bassInitialized: Boolean;
    songsamplerate: integer;
    
    { Function pointers }
    BassInit: TBassInit;
    BassFree: TBassFree;
    BassStreamCreateFile: TBassStreamCreateFile;
    BassStreamFree: TBassStreamFree;
    BassChannelGetInfo: TBassChannelGetInfo;
    BassChannelGetLength: TBassChannelGetLength;
    BassChannelSetPosition: TBassChannelSetPosition;
    BassChannelGetPosition: TBassChannelGetPosition;
    BassChannelGetData: TBassChannelGetData;
    BassErrorGetCode: TBassErrorGetCode;
    
    function LoadBassLibrary(const dllPath: string): Boolean;
    function UnloadBassLibrary: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    
    function InitializeBass: Boolean;
    function OpenMp3File(const filePath: string): Boolean;
    function CloseMp3File: Boolean;
    function AnalyzeMp3: Boolean;
    function GetDetectedBeats: TArray<Double>;
    function GetBPM: Double;
  end;

implementation

constructor TBassAudioProcessor.Create;
begin
  inherited Create;
  m_stream := 0;
  m_bassInitialized := False;
  m_analyzer := TQMBeatAnalyzer.Create;
  SetLength(m_sampleBuffer, 0);
  m_bassHandle := 0;
end;

destructor TBassAudioProcessor.Destroy;
begin
  { Cerrar stream si está abierto }
  if m_stream <> 0 then
    CloseMp3File;
  
  { Liberar BASS }
  if m_bassInitialized then
  begin
    BassFree;
    m_bassInitialized := False;
  end;
  
  { Liberar librería BASS }
  if m_bassHandle <> 0 then
    UnloadBassLibrary;
  
  { Liberar analizador }
  if m_analyzer <> nil then
  begin
    m_analyzer.Free;
    m_analyzer := nil;
  end;
  
  { Liberar buffer }
  SetLength(m_sampleBuffer, 0);
  
  inherited;
end;

function TBassAudioProcessor.LoadBassLibrary(const dllPath: string): Boolean;
begin
  m_bassHandle := LoadLibrary(PChar(dllPath));
  if m_bassHandle = 0 then
    Exit(False);
  
  @BassInit := GetProcAddress(m_bassHandle, 'BASS_Init');
  @BassFree := GetProcAddress(m_bassHandle, 'BASS_Free');
  @BassStreamCreateFile := GetProcAddress(m_bassHandle, 'BASS_StreamCreateFile');
  @BassStreamFree := GetProcAddress(m_bassHandle, 'BASS_StreamFree');
  @BassChannelGetLength := GetProcAddress(m_bassHandle, 'BASS_ChannelGetLength');
  @BassChannelSetPosition := GetProcAddress(m_bassHandle, 'BASS_ChannelSetPosition');
  @BassChannelGetPosition := GetProcAddress(m_bassHandle, 'BASS_ChannelGetPosition');
  @BassChannelGetData := GetProcAddress(m_bassHandle, 'BASS_ChannelGetData');
  @BassErrorGetCode := GetProcAddress(m_bassHandle, 'BASS_ErrorGetCode');
  
  Result := Assigned(BassInit) and Assigned(BassFree) and Assigned(BassStreamFree);
end;

function TBassAudioProcessor.UnloadBassLibrary: Boolean;
begin
  if m_bassHandle <> 0 then
    Result := FreeLibrary(m_bassHandle)
  else
    Result := True;
  m_bassHandle := 0;
end;

function TBassAudioProcessor.InitializeBass: Boolean;
begin
  if m_bassInitialized then
    Exit(True); { Ya está inicializado }
  
  if not LoadBassLibrary('bass.dll') then
    Exit(False);
  
  Result := BassInit(-1, 44100, 0, 0, nil);
  m_bassInitialized := Result;
end;

function TBassAudioProcessor.OpenMp3File(const filePath: string): Boolean;
var
  error: Integer;
  info: bass_channelinfo;
begin
  if not m_bassInitialized then
    Exit(False);

  { Cerrar stream anterior si existe }
  if m_stream <> 0 then
    CloseMp3File;

  m_stream := BassStreamCreateFile(False, PAnsiChar(filePath), 0, 0,
                                    BASS_STREAM_DECODE or BASS_SAMPLE_FLOAT or BASS_UNICODE);


  error := BassErrorGetCode;

  if m_stream = 0 then
    Exit(False);

  bass_channelgetinfo(m_stream, info);
  songsamplerate := info.freq;
  Result := m_analyzer.Initialize(songsamplerate);
end;

function TBassAudioProcessor.CloseMp3File: Boolean;
begin
  if m_stream <> 0 then
  begin
    Result := BassStreamFree(m_stream);
    m_stream := 0;
  end
  else
    Result := True;
end;

function TBassAudioProcessor.AnalyzeMp3: Boolean;
var
  bytesRead: DWORD;
  sampleCount: Integer;
  i: Integer;
  totalReaded: Integer;
  total: Int64;
begin
  Result := False;
  totalReaded := 0;
  
  if m_stream = 0 then
    Exit;
  
  { Set position to start }
  BassChannelSetPosition(m_stream, 0, 0);
  
  { Allocate buffer for reading samples }
  SetLength(m_sampleBuffer, 4096 * 2); { stereo }
  total := BassChannelGetLength(m_stream, 0); { BASS_POS_BYTE = 0 }
  
  repeat
    bytesRead := BassChannelGetData(m_stream, @m_sampleBuffer[0], SizeOf(Single) * Length(m_sampleBuffer));

    { BASS returns High(DWORD) = $FFFFFFFF on error (equivalent to -1 cast to DWORD).
      Treat both end-of-stream (0) and error as a signal to stop reading. }
    if (bytesRead = 0) or (bytesRead = High(DWORD)) then
      Break;

    totalReaded := totalReaded + bytesRead;

    sampleCount := bytesRead div SizeOf(Single);
    
    if not m_analyzer.ProcessSamples(m_sampleBuffer, sampleCount) then
      Break;
      
    if totalReaded >= total then
      Break;
      
  until bytesRead = 0;

  { Finalizar análisis }
  Result := m_analyzer.Finalize;
  
  { Limpiar buffer después del análisis }
  SetLength(m_sampleBuffer, 0);
end;

function TBassAudioProcessor.GetDetectedBeats: TArray<Double>;
begin
  Result := m_analyzer.GetBeats;
end;

function TBassAudioProcessor.GetBPM: Double;
begin
  Result := m_analyzer.GetBPM;
end;

end.