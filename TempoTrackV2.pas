unit TempoTrackV2;

interface

uses
  System.Generics.Collections, System.SysUtils, System.Math, FMathUtilities;

type
  { Type aliases para mantener compatibilidad con el código original }
  TDoubleVector = TArray<Double>;
  TIntVector = TArray<Integer>;
  TDoubleMatrix = TArray<TArray<Double>>;
  TIntMatrix = TArray<TArray<Integer>>;

  TTempoTrackV2 = class
  private
    m_rate: Single;
    m_increment: Integer;
    
    procedure FilterDF(var df: TDoubleVector);
    procedure GetRCF(const dfframe_in: TDoubleVector; const wv: TDoubleVector; var rcf: TDoubleVector);
    procedure ViterbiDecode(const rcfmat: TDoubleMatrix; const wv: TDoubleVector; var beat_period: TIntVector);
    function GetMaxVal(const df: TDoubleVector): Double;
    function GetMaxInd(const df: TDoubleVector): Integer;
    procedure NormaliseVec(var df: TDoubleVector);
  public
    constructor Create(rate: Single; increment: Integer);
    destructor Destroy; override;
    
    procedure CalculateBeatPeriod(const df: TDoubleVector; var beat_period: TIntVector); overload;
    procedure CalculateBeatPeriod(const df: TDoubleVector; var beat_period: TIntVector; 
                                  inputtempo: Double; constraintempo: Boolean); overload;
    
    procedure CalculateBeats(const df: TDoubleVector; const beat_period: TIntVector; 
                             var beats: TDoubleVector); overload;
    procedure CalculateBeats(const df: TDoubleVector; const beat_period: TIntVector; 
                             var beats: TDoubleVector; alpha: Double; tightness: Double); overload;
  end;

implementation

const
  EPS = 0.0000008;
  WV_LEN = 128;
  WINLEN = 512;
  HOPSIZE = 128;

constructor TTempoTrackV2.Create(rate: Single; increment: Integer);
begin
  inherited Create;
  m_rate := rate;
  m_increment := increment;
end;

destructor TTempoTrackV2.Destroy;
begin
  inherited;
end;

procedure TTempoTrackV2.FilterDF(var df: TDoubleVector);
var
  df_len: Integer;
  a, b: TDoubleVector;
  lp_df: TDoubleVector;
  inp1, inp2, out1, out2: Double;
  i: Integer;
begin
  df_len := Length(df);
  if df_len = 0 then Exit;
  
  SetLength(a, 3);
  SetLength(b, 3);
  SetLength(lp_df, df_len);
  
  { Butterworth filter coefficients equivalente a [b,a] = butter(2,0.4) en MATLAB }
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
    lp_df[i] := b[0] * df[i] + b[1] * inp1 + b[2] * inp2 - a[1] * out1 - a[2] * out2;
    inp2 := inp1;
    inp1 := df[i];
    out2 := out1;
    out1 := lp_df[i];
  end;
  
  { Copy forward filtering to df, time-reversed for backward filtering }
  for i := 0 to df_len - 1 do
    df[i] := lp_df[df_len - i - 1];
  
  { Clear lp_df }
  FillChar(lp_df[0], df_len * SizeOf(Double), 0);
  
  inp1 := 0.0;
  inp2 := 0.0;
  out1 := 0.0;
  out2 := 0.0;
  
  { Backward filtering on time-reversed df }
  for i := 0 to df_len - 1 do
  begin
    lp_df[i] := b[0] * df[i] + b[1] * inp1 + b[2] * inp2 - a[1] * out1 - a[2] * out2;
    inp2 := inp1;
    inp1 := df[i];
    out2 := out1;
    out1 := lp_df[i];
  end;
  
  { Write re-reversed version back to df }
  for i := 0 to df_len - 1 do
    df[i] := lp_df[df_len - i - 1];
end;

procedure TTempoTrackV2.GetRCF(const dfframe_in: TDoubleVector; const wv: TDoubleVector; var rcf: TDoubleVector);
var
  dfframe: TDoubleVector;
  dfframe_len, rcf_len: Integer;
  acf: TDoubleVector;
  lag, n: Integer;
  sum, tmp: Double;
  i, a, b: Integer;
  numelem: Integer;
  rcfsum: Double;
  j: Integer;
begin
  dfframe := Copy(dfframe_in);
  
  { Apply adaptive threshold }
  MathUtilities.AdaptiveThreshold(dfframe);
  
  dfframe_len := Length(dfframe);
  rcf_len := Length(rcf);
  
  { Calculate autocorrelation function }
  SetLength(acf, dfframe_len);
  
  for lag := 0 to dfframe_len - 1 do
  begin
    sum := 0.0;
    for n := 0 to dfframe_len - lag - 1 do
    begin
      tmp := dfframe[n] * dfframe[n + lag];
      sum := sum + tmp;
    end;
    
    if (dfframe_len - lag) > 0 then
      acf[lag] := sum / (dfframe_len - lag)
    else
      acf[lag] := 0.0;
  end;
  
  { Clear rcf }
  for i := 0 to rcf_len - 1 do
    rcf[i] := 0.0;
  
  { Apply comb filtering }
  numelem := 4;
  
  for i := 2 to rcf_len - 1 do
  begin
    for a := 1 to numelem do
    begin
      for b := (1 - a) to (a - 1) do
      begin
        if ((a * i + b) - 1) >= 0 then
        begin
          rcf[i - 1] := rcf[i - 1] + (acf[(a * i + b) - 1] * wv[i - 1]) / (2.0 * a - 1.0);
        end;
      end;
    end;
  end;
  
  { Apply adaptive threshold to rcf }
  MathUtilities.AdaptiveThreshold(rcf);
  
  rcfsum := 0.0;
  for i := 0 to rcf_len - 1 do
  begin
    rcf[i] := rcf[i] + EPS;
    rcfsum := rcfsum + rcf[i];
  end;
  
  { Normalize rcf to sum to unity }
  for i := 0 to rcf_len - 1 do
    rcf[i] := rcf[i] / (rcfsum + EPS);
  
  SetLength(acf, 0);
  SetLength(dfframe, 0);
end;

function TTempoTrackV2.GetMaxVal(const df: TDoubleVector): Double;
var
  i, df_len: Integer;
  maxval: Double;
begin
  maxval := 0.0;
  df_len := Length(df);
  
  for i := 0 to df_len - 1 do
  begin
    if maxval < df[i] then
      maxval := df[i];
  end;
  
  Result := maxval;
end;

function TTempoTrackV2.GetMaxInd(const df: TDoubleVector): Integer;
var
  i, df_len, ind: Integer;
  maxval: Double;
begin
  maxval := 0.0;
  ind := 0;
  df_len := Length(df);
  
  for i := 0 to df_len - 1 do
  begin
    if maxval < df[i] then
    begin
      maxval := df[i];
      ind := i;
    end;
  end;
  
  Result := ind;
end;

procedure TTempoTrackV2.NormaliseVec(var df: TDoubleVector);
var
  i, df_len: Integer;
  sum: Double;
begin
  sum := 0.0;
  df_len := Length(df);
  
  for i := 0 to df_len - 1 do
    sum := sum + df[i];
  
  for i := 0 to df_len - 1 do
    df[i] := df[i] / (sum + EPS);
end;

procedure TTempoTrackV2.ViterbiDecode(const rcfmat: TDoubleMatrix; const wv: TDoubleVector; var beat_period: TIntVector);
var
  numFrames, numStates: NativeUInt;
  tmat: TDoubleMatrix;
  sigma: Double;
  i, j: NativeUInt;
  mu: Double;
  delta: TDoubleMatrix;
  psi: TIntMatrix;
  tmp_vec: TDoubleVector;
  timeIdx: NativeUInt;
  deltasum: Double;
  backtraceIdx: Integer;
begin
  if Length(rcfmat) < 2 then Exit;
  
  numFrames := Length(rcfmat);
  numStates := Length(rcfmat[0]);
  
  { Resize beat_period if needed }
  SetLength(beat_period, numFrames);
  
  { Create transition matrix }
  SetLength(tmat, numStates);
  for i := 0 to numStates - 1 do
  begin
    SetLength(tmat[i], numStates);
    for j := 0 to numStates - 1 do
      tmat[i][j] := 0.0;
  end;
  
  sigma := 8.0;
  
  { Fill transition matrix with Gaussians }
  for i := 20 to numStates - 21 do
  begin
    for j := 20 to numStates - 21 do
    begin
      mu := Double(i);
      tmat[i][j] := Exp(-1.0 * Power((j - mu), 2) / (2.0 * Power(sigma, 2)));
    end;
  end;
  
  { Initialize delta and psi matrices }
  SetLength(delta, numFrames);
  SetLength(psi, numFrames);
  
  for i := 0 to numFrames - 1 do
  begin
    SetLength(delta[i], numStates);
    SetLength(psi[i], numStates);
    for j := 0 to numStates - 1 do
    begin
      delta[i][j] := 0.0;
      psi[i][j] := 0;
    end;
  end;
  
  { Initialize first column of delta }
  for j := 0 to numStates - 1 do
    delta[0][j] := wv[j] * rcfmat[0][j];
  
  { Normalize first column }
  deltasum := 0.0;
  for i := 0 to numStates - 1 do
    deltasum := deltasum + delta[0][i];
  
  for i := 0 to numStates - 1 do
    delta[0][i] := delta[0][i] / (deltasum + EPS);
  
  { Main Viterbi loop }
  for timeIdx := 1 to numFrames - 1 do
  begin
    SetLength(tmp_vec, numStates);
    
    for j := 0 to numStates - 1 do
    begin
      { Find max over previous states }
      for i := 0 to numStates - 1 do
        tmp_vec[i] := delta[timeIdx - 1][i] * tmat[j][i];
      
      delta[timeIdx][j] := GetMaxVal(tmp_vec);
      psi[timeIdx][j] := GetMaxInd(tmp_vec);
      
      { Multiply by observation probability }
      delta[timeIdx][j] := delta[timeIdx][j] * rcfmat[timeIdx][j];
    end;
    
    { Normalize delta column }
    deltasum := 0.0;
    for i := 0 to numStates - 1 do
      deltasum := deltasum + delta[timeIdx][i];
    
    for i := 0 to numStates - 1 do
      delta[timeIdx][i] := delta[timeIdx][i] / (deltasum + EPS);
    
    SetLength(tmp_vec, 0);
  end;
  
  { Backtrace }
  beat_period[numFrames - 1] := GetMaxInd(delta[numFrames - 1]);
  
  for backtraceIdx := Integer(numFrames - 2) downto 1 do
    beat_period[backtraceIdx] := psi[backtraceIdx + 1][beat_period[backtraceIdx + 1]];
  
  { Weird hack from original code }
  beat_period[0] := psi[1][beat_period[1]];
  
  { Cleanup }
  SetLength(tmat, 0);
  SetLength(delta, 0);
  SetLength(psi, 0);
  SetLength(tmp_vec, 0);
end;

procedure TTempoTrackV2.CalculateBeatPeriod(const df: TDoubleVector; var beat_period: TIntVector);
begin
  CalculateBeatPeriod(df, beat_period, 120.0, False);
end;

procedure TTempoTrackV2.CalculateBeatPeriod(const df: TDoubleVector; var beat_period: TIntVector; 
                                           inputtempo: Double; constraintempo: Boolean);
var
  wv: TDoubleVector;
  rayparam: Double;
  i: Integer;
  winlen, hopsize, df_len: Integer;
  rcfmat: TDoubleMatrix;
  dfframe: TDoubleVector;
  rcf: TDoubleVector;
  k, l: Integer;
  rcfmat_idx: Integer;
  j: Integer;
begin
  if Length(df) = 0 then Exit;
  
  { Initialize weighting vector }
  SetLength(wv, WV_LEN);
  
  { Calculate rayparam }
  rayparam := (60.0 * 44100.0 / 512.0) / inputtempo;
  
  { Create weighting vector }
  if constraintempo then
  begin
    { Gaussian weighting }
    for i := 0 to WV_LEN - 1 do
      wv[i] := Exp(-1.0 * Power((i - rayparam), 2) / (2.0 * Power(rayparam / 4.0, 2)));
  end
  else
  begin
    { Rayleigh weighting }
    for i := 0 to WV_LEN - 1 do
      wv[i] := (i / Power(rayparam, 2)) * Exp(-1.0 * Power(i, 2) / (2.0 * Power(rayparam, 2)));
  end;
  
  winlen := 512;
  hopsize := 128;
  df_len := Length(df);
  
  { Create rcf matrix }
  SetLength(rcfmat, (df_len div hopsize) + 2);
  rcfmat_idx := 0;
  
  SetLength(dfframe, winlen);
  SetLength(rcf, WV_LEN);
  
  { Process each window }
  i := -(winlen div 2);
  while i < (df_len - winlen div 2) do
  begin
    k := 0;
    l := winlen;
    
    { Fill with zeros if needed }
    if i < 0 then
    begin
      k := -i;
      FillChar(dfframe[0], k * SizeOf(Double), 0);
    end;
    
    if (i + l) > df_len then
    begin
      l := df_len - i;
      FillChar(dfframe[l], (winlen - l) * SizeOf(Double), 0);
    end;
    
    { Copy data }
    if l > k then
      Move(df[i + k], dfframe[k], (l - k) * SizeOf(Double));
    
    { Clear rcf }
    for j := 0 to WV_LEN - 1 do
      rcf[j] := 0.0;
    
    { Get resonator comb filter response }
    GetRCF(dfframe, wv, rcf);
    
    { Append to matrix }
    SetLength(rcfmat[rcfmat_idx], WV_LEN);
    for j := 0 to WV_LEN - 1 do
      rcfmat[rcfmat_idx][j] := rcf[j];
    
    Inc(rcfmat_idx);
    i := i + hopsize;
  end;
  
  { Resize rcfmat to actual size }
  SetLength(rcfmat, rcfmat_idx);
  
  { Viterbi decoding }
  ViterbiDecode(rcfmat, wv, beat_period);
  
  { Cleanup }
  SetLength(wv, 0);
  SetLength(dfframe, 0);
  SetLength(rcf, 0);
  SetLength(rcfmat, 0);
end;

procedure TTempoTrackV2.CalculateBeats(const df: TDoubleVector; const beat_period: TIntVector; 
                                       var beats: TDoubleVector);
begin
  CalculateBeats(df, beat_period, beats, 0.9, 4.0);
end;

procedure TTempoTrackV2.CalculateBeats(const df: TDoubleVector; const beat_period: TIntVector; 
                                       var beats: TDoubleVector; alpha: Double; tightness: Double);
var
  df_len: Integer;
  cumscore, localscore: TDoubleVector;
  backlink: TIntVector;
  i, j: Integer;
  old_period, period: Integer;
  prange_min, prange_max, txwt_len: Integer;
  txwt: TDoubleVector;
  mu: Double;
  vv: Double;
  xx: Integer;
  cscore_ind: Integer;
  scorecands: Double;
  tmp_vec: TDoubleVector;
  startpoint: Integer;
  ibeats: TIntVector;
  b: Integer;
begin
  if (Length(df) = 0) or (Length(beat_period) = 0) then Exit;
  
  df_len := Length(df);
  
  { Initialize arrays }
  SetLength(cumscore, df_len);
  SetLength(backlink, df_len);
  SetLength(localscore, df_len);
  SetLength(txwt, 0);
  
  for i := 0 to df_len - 1 do
  begin
    localscore[i] := df[i];
    backlink[i] := -1;
    cumscore[i] := 0.0;
  end;
  
  old_period := 0;
  txwt_len := 0;
  
  { Main dynamic programming loop }
  for i := 0 to df_len - 1 do
  begin
    period := beat_period[i div 128];
    prange_min := period * -2;
    
    if period <> old_period then
    begin
      old_period := period;
      prange_max := period div -2;
      
      txwt_len := prange_max - prange_min + 1;
      SetLength(txwt, txwt_len);
      
      for j := 0 to txwt_len - 1 do
      begin
        mu := Double(period);
        txwt[j] := Exp(-0.5 * Power(tightness * Ln((Round(2 * mu) - j) / mu), 2));
      end;
    end;
    
    { Find best previous beat }
    vv := 0.0;
    xx := 0;
    
    for j := 0 to txwt_len - 1 do
    begin
      cscore_ind := i + prange_min + j;
      if cscore_ind >= 0 then
      begin
        scorecands := txwt[j] * cumscore[cscore_ind];
        if scorecands > vv then
        begin
          vv := scorecands;
          xx := cscore_ind;
        end;
      end;
    end;
    
    cumscore[i] := alpha * vv + (1.0 - alpha) * localscore[i];
    backlink[i] := xx;
  end;
  
  { Find starting point - last beat }
  SetLength(tmp_vec, beat_period[Length(beat_period) - 1]);
  for i := 0 to Length(tmp_vec) - 1 do
  begin
    if (df_len - beat_period[Length(beat_period) - 1] + i) < df_len then
      tmp_vec[i] := cumscore[df_len - beat_period[Length(beat_period) - 1] + i]
    else
      tmp_vec[i] := 0.0;
  end;
  
  startpoint := GetMaxInd(tmp_vec) + df_len - beat_period[Length(beat_period) - 1];
  
  if startpoint >= df_len then
    startpoint := df_len - 1;
  
  { Backtrace to find all beats }
  SetLength(ibeats, 0);
  ibeats := [startpoint];
  
  while (Length(ibeats) > 0) and (backlink[ibeats[High(ibeats)]] > 0) do
  begin
    b := ibeats[High(ibeats)];
    if backlink[b] = b then Break;
    SetLength(ibeats, Length(ibeats) + 1);
    ibeats[High(ibeats)] := backlink[b];
  end;
  
  { Reverse sequence and convert to beats }
  SetLength(beats, Length(ibeats));
  for i := 0 to High(ibeats) do
    beats[i] := Double(ibeats[Length(ibeats) - i - 1]);
  
  { Cleanup }
  SetLength(cumscore, 0);
  SetLength(backlink, 0);
  SetLength(localscore, 0);
  SetLength(txwt, 0);
  SetLength(tmp_vec, 0);
  SetLength(ibeats, 0);
end;

end.