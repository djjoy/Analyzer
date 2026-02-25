unit DetectionFunction;

interface

uses
  System.SysUtils, System.Math, System.Generics.Collections, KissFFT, FMathUtilities;

const
  DF_HFC = 1;
  DF_SPECDIFF = 2;
  DF_PHASEDEV = 3;
  DF_COMPLEXSD = 4;
  DF_BROADBAND = 5;

type
  TDFConfig = record
    stepSize: Integer;
    frameLength: Integer;
    DFType: Integer;
    dbRise: Double;
    adaptiveWhitening: Boolean;
    whiteningRelaxCoeff: Double;
    whiteningFloor: Double;
  end;

  TDetectionFunction = class
  private
    m_DFType: Integer;
    m_dataLength: Integer;
    m_halfLength: Integer;
    m_stepSize: Integer;
    m_dbRise: Double;
    m_whiten: Boolean;
    m_whitenRelaxCoeff: Double;
    m_whitenFloor: Double;
    
    m_magHistory: TArray<Double>;
    m_phaseHistory: TArray<Double>;
    m_phaseHistoryOld: TArray<Double>;
    m_magPeaks: TArray<Double>;
    
    m_windowed: TArray<Double>;
    m_fftCpxInput: Tkiss_fft_cpx_array;
    m_fftCpxOutput: Tkiss_fft_cpx_array;
    m_magnitude: TArray<Double>;
    m_phase: TArray<Double>;
    m_fft_cfg: kiss_fft_cfg;
    
    procedure Initialize(config: TDFConfig);
    procedure DeInitialize;
    procedure ApplyHanningWindow(const samples: TArray<Double>; var windowed: TArray<Double>);
    procedure Whiten;
    function RunDF: Double;
    function ComplexSD: Double;
    function HFC: Double;
    function SpecDiff: Double;
  public
    constructor Create(config: TDFConfig);
    destructor Destroy; override;
    
    function ProcessTimeDomain(const samples: TArray<Double>): Double;
    function GetSpectrumMagnitude: TArray<Double>;
  end;

implementation

constructor TDetectionFunction.Create(config: TDFConfig);
begin
  inherited Create;
  Initialize(config);
end;

destructor TDetectionFunction.Destroy;
begin
  DeInitialize;
  inherited;
end;

procedure TDetectionFunction.Initialize(config: TDFConfig);
var
  i: Integer;
begin
  m_dataLength := config.frameLength;
  m_halfLength := m_dataLength div 2 + 1;
  m_DFType := config.DFType;
  m_stepSize := config.stepSize;
  m_dbRise := config.dbRise;
  m_whiten := config.adaptiveWhitening;
  m_whitenRelaxCoeff := config.whiteningRelaxCoeff;
  m_whitenFloor := config.whiteningFloor;
  
  if m_whitenRelaxCoeff < 0 then
    m_whitenRelaxCoeff := 0.9997;
  if m_whitenFloor < 0 then
    m_whitenFloor := 0.01;
  
  SetLength(m_magHistory, m_halfLength);
  SetLength(m_phaseHistory, m_halfLength);
  SetLength(m_phaseHistoryOld, m_halfLength);
  SetLength(m_magPeaks, m_halfLength);
  SetLength(m_magnitude, m_halfLength);
  SetLength(m_phase, m_halfLength);
  SetLength(m_windowed, m_dataLength);
  SetLength(m_fftCpxInput, m_dataLength);
  
  FillChar(m_magHistory[0], SizeOf(Double) * m_halfLength, 0);
  FillChar(m_phaseHistory[0], SizeOf(Double) * m_halfLength, 0);
  FillChar(m_phaseHistoryOld[0], SizeOf(Double) * m_halfLength, 0);
  FillChar(m_magPeaks[0], SizeOf(Double) * m_halfLength, 0);
  
  { Inicializar FFT }
  m_fft_cfg := kiss_fft_alloc(m_dataLength, False);
end;

procedure TDetectionFunction.DeInitialize;
begin
  SetLength(m_magHistory, 0);
  SetLength(m_phaseHistory, 0);
  SetLength(m_phaseHistoryOld, 0);
  SetLength(m_magPeaks, 0);
  SetLength(m_magnitude, 0);
  SetLength(m_phase, 0);
  SetLength(m_windowed, 0);
  SetLength(m_fftCpxInput, 0);
  SetLength(m_fftCpxOutput, 0);
  SetLength(m_fft_cfg.twiddles, 0);
  SetLength(m_fft_cfg.factors, 0);
end;

procedure TDetectionFunction.ApplyHanningWindow(const samples: TArray<Double>; 
  var windowed: TArray<Double>);
var
  i: Integer;
  n: Integer;
begin
  n := Length(samples);
  if n = 0 then Exit;
  
  SetLength(windowed, n);
  for i := 0 to n - 1 do
  begin
    windowed[i] := samples[i] * (0.5 - 0.5 * Cos(2.0 * PI * i / (n - 1)));
  end;
end;

procedure TDetectionFunction.Whiten;
var
  i: Integer;
begin
  if not m_whiten then Exit;
  
  for i := 0 to m_halfLength - 1 do
  begin
    if m_magHistory[i] > 0 then
      m_magnitude[i] := m_magnitude[i] / m_magHistory[i];
    
    m_magHistory[i] := m_magHistory[i] * m_whitenRelaxCoeff + 
                       m_magnitude[i] * (1.0 - m_whitenRelaxCoeff);
    
    if m_magHistory[i] < m_whitenFloor then
      m_magHistory[i] := m_whitenFloor;
  end;
end;

function TDetectionFunction.ComplexSD: Double;
var
  i: Integer;
  real_part, imag_part: Double;
  sd: Double;
  predictedPhase: Double;
begin
  sd := 0;
  
  for i := 0 to m_halfLength - 1 do
  begin
    { Phase prediction: 2nd-order linear extrapolation wrapped to [-pi, pi].
      Stationary tones have predictable phase progression and contribute near
      zero; sudden changes (onsets) produce large deviations. }
    predictedPhase := MathUtilities.PrincArg(
      2.0 * m_phaseHistory[i] - m_phaseHistoryOld[i]);

    real_part := m_magnitude[i] * Cos(m_phase[i]) - m_magHistory[i] * Cos(predictedPhase);
    imag_part := m_magnitude[i] * Sin(m_phase[i]) - m_magHistory[i] * Sin(predictedPhase);
    
    sd := sd + Sqrt(real_part * real_part + imag_part * imag_part);
    
    m_phaseHistoryOld[i] := m_phaseHistory[i];
    m_phaseHistory[i] := m_phase[i];
    m_magHistory[i] := m_magnitude[i];
  end;
  
  Result := sd;
end;

function TDetectionFunction.HFC: Double;
var
  i: Integer;
  hfc: Double;
begin
  hfc := 0;
  for i := 0 to m_halfLength - 1 do
    hfc := hfc + i * m_magnitude[i];
  Result := hfc;
end;

function TDetectionFunction.SpecDiff: Double;
var
  i: Integer;
  sd: Double;
  diff: Double;
begin
  sd := 0;
  for i := 0 to m_halfLength - 1 do
  begin
    diff := m_magnitude[i] - m_magHistory[i];
    if diff > 0 then
      sd := sd + diff;
    m_magHistory[i] := m_magnitude[i];
  end;
  Result := sd;
end;

function TDetectionFunction.RunDF: Double;
begin
  case m_DFType of
    DF_HFC:
      Result := HFC;
    DF_SPECDIFF:
      Result := SpecDiff;
    DF_COMPLEXSD:
      Result := ComplexSD;
  else
    Result := 0;
  end;
end;

function TDetectionFunction.ProcessTimeDomain(const samples: TArray<Double>): Double;
var
  i: Integer;
begin
  if Length(samples) <> m_dataLength then
    Exit(0);
  
  ApplyHanningWindow(samples, m_windowed);
  
  { Preparar entrada para FFT }
  for i := 0 to m_dataLength - 1 do
  begin
    m_fftCpxInput[i].r := m_windowed[i];
    m_fftCpxInput[i].i := 0;
  end;
  
  { Ejecutar FFT }
  kiss_fft(m_fft_cfg, m_fftCpxInput, m_fftCpxOutput);
  
  { Extraer magnitud y fase }
  for i := 0 to m_halfLength - 1 do
  begin
    m_magnitude[i] := Sqrt(m_fftCpxOutput[i].r * m_fftCpxOutput[i].r + 
                           m_fftCpxOutput[i].i * m_fftCpxOutput[i].i);
    if m_magnitude[i] > 0 then
      m_phase[i] := ArcTan2(m_fftCpxOutput[i].i, m_fftCpxOutput[i].r)
    else
      m_phase[i] := 0;
  end;
  
  if m_whiten then
    Whiten;
  
  Result := RunDF;
end;

function TDetectionFunction.GetSpectrumMagnitude: TArray<Double>;
begin
  Result := m_magnitude;
end;

end.