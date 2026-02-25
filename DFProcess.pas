unit DFProcess;

{ Port of qm-dsp signalconditioning/DFProcess.
  Conditions the raw detection function before it is fed to TempoTrackV2:
    1. Single-pass Butterworth low-pass filter  - removes high-frequency noise
       from the DF while preserving the beat-rate energy.
    2. Adaptive mean subtraction + half-wave rectification (AdaptiveThreshold)
       - removes slowly-varying DC bias and keeps only positive onset peaks.

  This mirrors the role of DFProcess in the original qm-dsp library. }

interface

type
  TDFProcess = class
  public
    { Conditions df in-place: LP filter followed by adaptive threshold. }
    class procedure Process(var df: TArray<Double>); static;
  end;

implementation

uses
  FMathUtilities;

{ TDFProcess }

class procedure TDFProcess.Process(var df: TArray<Double>);
var
  df_len: Integer;
  b0, b1, b2: Double;
  a1, a2: Double;
  inp1, inp2, out1, out2: Double;
  i: Integer;
  filtered: TArray<Double>;
begin
  df_len := Length(df);
  if df_len = 0 then Exit;

  { Step 1: Single-pass 2nd-order Butterworth low-pass filter.
    Coefficients from butter(2, 0.4) in MATLAB / SciPy notation.
    The same coefficients are used by FilterDF inside TempoTrackV2 (zero-phase
    version).  Here we apply a causal forward-only pass so that the output
    passed to CalculateBeats' local-score does not receive extra phase
    distortion beyond the normal onset-detection delay. }
  b0 := 0.2066; b1 := 0.4131; b2 := 0.2066;
  a1 := -0.3695; a2 := 0.1958;

  SetLength(filtered, df_len);
  inp1 := 0.0; inp2 := 0.0;
  out1 := 0.0; out2 := 0.0;

  for i := 0 to df_len - 1 do
  begin
    filtered[i] := b0*df[i] + b1*inp1 + b2*inp2 - a1*out1 - a2*out2;
    inp2 := inp1; inp1 := df[i];
    out2 := out1; out1 := filtered[i];
  end;

  Move(filtered[0], df[0], df_len * SizeOf(Double));
  SetLength(filtered, 0);

  { Step 2: Subtract adaptive (sliding-window) mean and half-wave rectify.
    This removes residual DC bias and ensures only genuine onset peaks remain,
    equalising energy across quiet and loud sections of the track. }
  MathUtilities.AdaptiveThreshold(df);
end;

end.
