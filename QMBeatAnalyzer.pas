unit QMBeatAnalyzer;

interface

uses
  System.SysUtils, System.Generics.Collections, System.Math,
  DetectionFunction, TempoTrackV2;

type
type
  TQMBeatAnalyzer = class
  private
    m_pDetectionFunction: TDetectionFunction;
    m_tempoTracker: TTempoTrackV2;
    m_sampleRate: Integer;
    m_windowSize: Integer;
    m_stepSizeFrames: Integer;
    m_detectionResults: TList<Double>;
    m_resultBeats: TList<Double>;
    m_windowBuffer: TArray<Double>;
    m_windowFillCount: Integer;
    
    procedure ProcessWindow(const pWindow: TArray<Double>);
    { Redondea el BPM al valor más preciso dentro del rango de tolerancia,
      igual que BeatUtils::roundBpmWithinRange de Mixxx.
      Intenta: entero, 0.5, 1/3 y 1/12 de BPM en ese orden. }
    function RoundBpmWithinRange(minBpm, centerBpm, maxBpm: Double): Double;
  public
    constructor Create;
    destructor Destroy; override;
    
    function Initialize(sampleRate: Integer): Boolean;
    function ProcessSamples(const pIn: TArray<Single>; iLen: Integer): Boolean;
    function Finalize: Boolean;
    
    function GetBeats: TArray<Double>;
    function GetBPM: Double;
    function GetSampleRate: Integer;
    function GetStepSizeFrames: Integer;
  end;

const
  kStepSecs = 0.01161;
  kMaximumBinSizeHz = 50;
  kAnalysisChannels = 2;

implementation

constructor TQMBeatAnalyzer.Create;
begin
  inherited Create;
  m_detectionResults := TList<Double>.Create;
  m_resultBeats := TList<Double>.Create;
  m_windowFillCount := 0;
  m_sampleRate := 0;
  m_windowSize := 0;
  m_stepSizeFrames := 0;
end;

destructor TQMBeatAnalyzer.Destroy;
begin
  m_detectionResults.Free;
  m_resultBeats.Free;
  if Assigned(m_pDetectionFunction) then
    m_pDetectionFunction.Free;
  if Assigned(m_tempoTracker) then
    m_tempoTracker.Free;
  SetLength(m_windowBuffer, 0);
  inherited;
end;

function TQMBeatAnalyzer.Initialize(sampleRate: Integer): Boolean;
var
  config: TDFConfig;
  nextPower: Integer;
begin
  Result := False;
  
  m_detectionResults.Clear;
  m_resultBeats.Clear;
  m_sampleRate := sampleRate;
  
  { Calculate step size in samples }
  m_stepSizeFrames := Trunc(m_sampleRate * kStepSecs);
  
  { Calculate window size as next power of 2 }
  nextPower := Trunc(m_sampleRate / kMaximumBinSizeHz);
  m_windowSize := 1;
  while m_windowSize < nextPower do
    m_windowSize := m_windowSize shl 1;
  
  if m_windowSize < 512 then m_windowSize := 512;
  if m_windowSize > 8192 then m_windowSize := 8192;
  
  { Initialize detection function }
  config.stepSize := m_stepSizeFrames;
  config.frameLength := m_windowSize;
  config.DFType := DF_COMPLEXSD;
  config.dbRise := 3;
  config.adaptiveWhitening := False;
  config.whiteningRelaxCoeff := -1;
  config.whiteningFloor := -1;
  
  if Assigned(m_pDetectionFunction) then
    m_pDetectionFunction.Free;
  
  m_pDetectionFunction := TDetectionFunction.Create(config);
  
  if Assigned(m_tempoTracker) then
    m_tempoTracker.Free;
  
  m_tempoTracker := TTempoTrackV2.Create(m_sampleRate, m_stepSizeFrames);
  
  SetLength(m_windowBuffer, m_windowSize);
  { Start with the first half of the window pre-filled with zeros, matching
    Mixxx's DownmixAndOverlapHelper which sets m_bufferWritePosition = windowSize/2.
    This centres the first analysis frame at the beginning of the track.
    Note: SetLength zero-initialises new memory in Delphi, so no explicit fill needed. }
  m_windowFillCount := m_windowSize div 2;
  
  Result := True;
end;

procedure TQMBeatAnalyzer.ProcessWindow(const pWindow: TArray<Double>);
var
  dfValue: Double;
begin
  if not Assigned(m_pDetectionFunction) then
    Exit;
  
  dfValue := m_pDetectionFunction.ProcessTimeDomain(pWindow);
  m_detectionResults.Add(dfValue);
end;

function TQMBeatAnalyzer.ProcessSamples(const pIn: TArray<Single>; iLen: Integer): Boolean;
var
  i, j: Integer;
  sampleIdx: Integer;
begin
  Result := False;
  
  if not Assigned(m_pDetectionFunction) then
    Exit;
  
  if (iLen mod kAnalysisChannels) <> 0 then
    Exit;
  
  { Convert stereo samples to mono and fill window }
  sampleIdx := 0;
  for i := 0 to (iLen div kAnalysisChannels) - 1 do
  begin
    { Average stereo channels in Double precision.
      Audio samples arrive as Single from BASS; promoting to Double before
      the addition ensures the average is computed without Single-precision
      rounding, consistent with the Double-precision analysis pipeline. }
    m_windowBuffer[m_windowFillCount] :=
      (Double(pIn[sampleIdx]) + Double(pIn[sampleIdx + 1])) * 0.5;
    Inc(m_windowFillCount);
    Inc(sampleIdx, 2);
    
    { Process window when full }
    if m_windowFillCount >= m_windowSize then
    begin
      ProcessWindow(m_windowBuffer);
      
      { Shift window for overlap }
      for j := 0 to m_windowSize - m_stepSizeFrames - 1 do
        m_windowBuffer[j] := m_windowBuffer[j + m_stepSizeFrames];
      
      m_windowFillCount := m_windowSize - m_stepSizeFrames;
    end;
  end;
  
  Result := True;
end;

function TQMBeatAnalyzer.Finalize: Boolean;
var
  i, nonZeroCount: Integer;
  df: TArray<Double>;
  beatPeriod: TArray<Integer>;
  beats: TArray<Double>;
  beatFrame: Double;
  halfStep: Double;
  zeroBuf: TArray<Single>;
begin
  Result := False;

  { Append windowSize/2 silence frames before finalising, matching
    Mixxx's DownmixAndOverlapHelper::finalize() which appends
    max(framesToFillWindow, windowSize/2 - 1) zero frames. This flushes
    any partially-filled window and captures beats near the end of the track.
    ProcessSamples expects stereo-interleaved samples, so m_windowSize
    samples = m_windowSize div 2 mono frames = m_windowSize div 2 silence. }
  SetLength(zeroBuf, m_windowSize);
  ProcessSamples(zeroBuf, m_windowSize);
  SetLength(zeroBuf, 0);

  { Find last non-zero detection result }
  nonZeroCount := m_detectionResults.Count;
  while (nonZeroCount > 0) and (m_detectionResults[nonZeroCount - 1] <= 0.0) do
    Dec(nonZeroCount);
  
  if nonZeroCount < 3 then
    Exit(True);
  
  { Prepare detection function array, skipping first 2 results }
  SetLength(df, nonZeroCount - 2);
  for i := 2 to nonZeroCount - 1 do
    df[i - 2] := m_detectionResults[i];
  
  { Calculate beat period }
  SetLength(beatPeriod, 0);
  m_tempoTracker.CalculateBeatPeriod(df, beatPeriod);
  
  { Calculate beats }
  SetLength(beats, 0);
  m_tempoTracker.CalculateBeats(df, beatPeriod, beats);
  
  { Convert beat DF indices to audio frame positions.
    Add m_stepSizeFrames/2: beat is detected between surrounding analysis
    frames, matching Mixxx: (beats[i] * m_stepSizeFrames) + m_stepSizeFrames/2. }
  halfStep := m_stepSizeFrames / 2;
  m_resultBeats.Clear;
  for i := 0 to Length(beats) - 1 do
  begin
    beatFrame := beats[i] * m_stepSizeFrames + halfStep;
    m_resultBeats.Add(beatFrame);
  end;
  
  Result := True;
end;

function TQMBeatAnalyzer.GetBeats: TArray<Double>;
var
  i: Integer;
begin
  SetLength(Result, m_resultBeats.Count);
  for i := 0 to m_resultBeats.Count - 1 do
    Result[i] := m_resultBeats[i];
end;

{ Intenta redondear BPM a un múltiplo de 1/fraction dentro del rango [minBpm, maxBpm].
  Equivale a BeatUtils::trySnap de Mixxx. }
function TrySnap(minBpm, centerBpm, maxBpm, fraction: Double): Double;
var
  snapped: Double;
begin
  snapped := Round(centerBpm * fraction) / fraction;
  if (snapped > minBpm) and (snapped < maxBpm) then
    Result := snapped
  else
    Result := 0.0; { 0 = no encontrado }
end;

function TQMBeatAnalyzer.RoundBpmWithinRange(minBpm, centerBpm, maxBpm: Double): Double;
var
  snapped: Double;
begin
  { 1. Intentar BPM entero }
  snapped := TrySnap(minBpm, centerBpm, maxBpm, 1.0);
  if snapped > 0 then
  begin
    Result := snapped;
    Exit;
  end;

  { 2. Intentar 0.5 BPM solo para tempos lentos (<85 BPM) }
  if centerBpm < 85.0 then
  begin
    snapped := TrySnap(minBpm, centerBpm, maxBpm, 2.0);
    if snapped > 0 then
    begin
      Result := snapped;
      Exit;
    end;
  end;

  { 3. Para tempos rápidos (>127 BPM) intentar múltiplo de 2/3 }
  if centerBpm > 127.0 then
  begin
    snapped := TrySnap(minBpm, centerBpm, maxBpm, 2.0 / 3.0);
    if snapped > 0 then
    begin
      Result := snapped;
      Exit;
    end;
  end;

  { 4. Intentar 1/3 BPM }
  snapped := TrySnap(minBpm, centerBpm, maxBpm, 3.0);
  if snapped > 0 then
  begin
    Result := snapped;
    Exit;
  end;

  { 5. Intentar 1/12 BPM }
  snapped := TrySnap(minBpm, centerBpm, maxBpm, 12.0);
  if snapped > 0 then
  begin
    Result := snapped;
    Exit;
  end;

  { Sin redondeo posible: devolver el valor central }
  Result := centerBpm;
end;

function TQMBeatAnalyzer.GetBPM: Double;
var
  beats: TArray<Double>;
  avgBeatInterval: Double;
  centerBpm: Double;
  tolerance: Double;
begin
  beats := GetBeats;

  Result := 0;

  if Length(beats) < 2 then
    Exit;

  { Intervalo promedio entre beats en frames de audio (span total).
    Usar el span completo (primer beat al último) en lugar de un
    promedio frame-by-frame da una estimación más precisa porque
    los errores de posición individuales (±12 ms por el step del DF)
    se promedian sobre todos los intervalos. }
  avgBeatInterval := (beats[High(beats)] - beats[0]) / (Length(beats) - 1);

  if avgBeatInterval <= 0 then
    Exit;

  centerBpm := (60.0 * m_sampleRate) / avgBeatInterval;

  { Tolerancia de 25 ms convertida a BPM (igual que Mixxx kMaxSecsPhaseError).
    Derivación: dBPM = BPM² × kMaxSecsPhaseError / 60
    Ej: 120 BPM → ±0.6 BPM; 140 BPM → ±0.8 BPM }
  tolerance := centerBpm * centerBpm * 0.025 / 60.0;

  Result := RoundBpmWithinRange(centerBpm - tolerance, centerBpm, centerBpm + tolerance);
end;

function TQMBeatAnalyzer.GetSampleRate: Integer;
begin
  Result := m_sampleRate;
end;

function TQMBeatAnalyzer.GetStepSizeFrames: Integer;
begin
  Result := m_stepSizeFrames;
end;

end.