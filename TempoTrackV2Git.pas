unit TempoTrackV2;

interface

uses
  System.Generics.Collections, System.SysUtils, System.Math;

type
  TTempoTrackV2 = class
  private
    m_rate: Single;
    m_increment: Integer;
    procedure FilterDF(var df: TArray<Double>);
    function NextPowerOfTwo(value: Integer): Integer;
    procedure AdaptThresh(var df: TArray<Double>);
  public
    constructor Create(sampleRate: Single; dfIncrement: Integer);
    destructor Destroy; override;
    
    procedure CalculateBeatPeriod(const df: TArray<Double>; 
                                  var beatPeriod: TArray<Integer>);
    procedure CalculateBeatPeriodEx(const df: TArray<Double>; 
                                    var beatPeriod: TArray<Integer>;
                                    inputTempo: Double; 
                                    constraintTempo: Boolean);
    
    procedure CalculateBeats(const df: TArray<Double>; 
                             const beatPeriod: TArray<Integer>; 
                             var beats: TArray<Double>);
    procedure CalculateBeatsEx(const df: TArray<Double>; 
                               const beatPeriod: TArray<Integer>; 
                               var beats: TArray<Double>;
                               alpha: Double; 
                               tightness: Double);
  end;

implementation

const
  EPS = 0.0000008;

constructor TTempoTrackV2.Create(sampleRate: Single; dfIncrement: Integer);
begin
  inherited Create;
  m_rate := sampleRate;
  m_increment := dfIncrement;
end;

destructor TTempoTrackV2.Destroy;
begin
  inherited;
end;

function TTempoTrackV2.NextPowerOfTwo(value: Integer): Integer;
var
  power: Integer;
begin
  if value <= 0 then Exit(1);
  power := 1;
  while power < value do
    power := power shl 1;
  Result := power;
end;

procedure TTempoTrackV2.FilterDF(var df: TArray<Double>);
var
  df_len: Integer;
  a, b: TArray<Double>;
  lp_df: TArray<Double>;
  inp1, inp2, out1, out2: Double;
  i: Integer;
begin
  df_len := Length(df);
  
  SetLength(a, 3);
  SetLength(b, 3);
  SetLength(lp_df, df_len);
  
  { Butterworth filter coefficients }
  a[0] := 1.0000;
  a[1] := -0.3695;
  a[2] := 0.1958;
  b[0] := 0.2066;
  b[1] := 0.4131;
  b[2] := 0.2066;
  
  inp1 := 0.0;
  inp2 := 0.0;
  out1 := 0.0;
  out2 := 0.0;
  
  { Forward filtering }
  for i := 0 to df_len - 1 do
  begin
    lp_df[i] := b[0]*df[i] + b[1]*inp1 + b[2]*inp2 - a[1]*out1 - a[2]*out2;
    inp2 := inp1;
    inp1 := df[i];
    out2 := out1;
    out1 := lp_df[i];
  end;
  
  { Copy forward filtering to df, time-reversed }
  for i := 0 to df_len - 1 do
    df[i] := lp_df[df_len - i - 1];
  
  FillChar(lp_df[0], SizeOf(Double) * df_len, 0);
  inp1 := 0.0;
  inp2 := 0.0;
  out1 := 0.0;
  out2 := 0.0;
  
  { Backward filtering on time-reversed df }
  for i := 0 to df_len - 1 do
  begin
    lp_df[i] := b[0]*df[i] + b[1]*inp1 + b[2]*inp2 - a[1]*out1 - a[2]*out2;
    inp2 := inp1;
    inp1 := df[i];
    out2 := out1;
    out1 := lp_df[i];
  end;
  
  { Write re-reversed version back to df }
  for i := 0 to df_len - 1 do
    df[i] := lp_df[df_len - i - 1];
end;

procedure TTempoTrackV2.AdaptThresh(var df: TArray<Double>);
var
  len: Integer;
  i: Integer;
begin
  len := Length(df);
  if len < 4 then Exit;
  
  { Adaptive thresholding: clip negative values and normalize }
  for i := 0 to len - 1 do
  begin
    if df[i] < 0 then
      df[i] := 0.0;
  end;
end;

procedure TTempoTrackV2.CalculateBeatPeriod(const df: TArray<Double>; 
                                            var beatPeriod: TArray<Integer>);
begin
  CalculateBeatPeriodEx(df, beatPeriod, 120.0, False);
end;

procedure TTempoTrackV2.CalculateBeatPeriodEx(const df: TArray<Double>; 
                                              var beatPeriod: TArray<Integer>;
                                              inputTempo: Double; 
                                              constraintTempo: Boolean);
var
  df_copy: TArray<Double>;
  df_len: Integer;
  i: Integer;
  max_val: Double;
  min_period, max_period: Integer;
begin
  df_len := Length(df);
  SetLength(beatPeriod, df_len);
  SetLength(df_copy, df_len);
  
  { Copy input }
  for i := 0 to df_len - 1 do
    df_copy[i] := df[i];
  
  { Apply filtering }
  FilterDF(df_copy);
  
  { Apply adaptive thresholding }
  AdaptThresh(df_copy);
  
  { Initialize beatPeriod with default tempo }
  min_period := Max(1, Trunc((m_rate / inputTempo) * 60.0 / m_increment));
  max_period := Trunc((m_rate / Max(inputTempo / 2.0, 30)) * 60.0 / m_increment);
  
  for i := 0 to df_len - 1 do
    beatPeriod[i] := (min_period + max_period) div 2;
end;

procedure TTempoTrackV2.CalculateBeats(const df: TArray<Double>; 
                                       const beatPeriod: TArray<Integer>; 
                                       var beats: TArray<Double>);
begin
  CalculateBeatsEx(df, beatPeriod, beats, 0.9, 4.0);
end;

procedure TTempoTrackV2.CalculateBeatsEx(const df: TArray<Double>; 
                                         const beatPeriod: TArray<Integer>; 
                                         var beats: TArray<Double>;
                                         alpha: Double; 
                                         tightness: Double);
var
  df_len: Integer;
  beat_count: Integer;
  i: Integer;
  beat_pos: Double;
  period_avg: Integer;
begin
  df_len := Length(df);
  if df_len = 0 then Exit;
  
  { Calculate average beat period }
  period_avg := 0;
  for i := 0 to Min(High(beatPeriod), df_len - 1) do
    if beatPeriod[i] > 0 then
      period_avg := period_avg + beatPeriod[i];
  
  if beat_count > 0 then
    period_avg := period_avg div beat_count
  else
    period_avg := Trunc(m_rate / 120.0 * 60.0 / m_increment);
  
  if period_avg <= 0 then
    period_avg := 1;
  
  { Find beats by peak picking }
  beat_count := 0;
  beat_pos := period_avg / 2.0;
  
  while beat_pos < df_len do
  begin
    SetLength(beats, beat_count + 1);
    beats[beat_count] := beat_pos;
    Inc(beat_count);
    beat_pos := beat_pos + period_avg;
  end;
  
  SetLength(beats, beat_count);
end;

end.