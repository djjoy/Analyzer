unit FMathUtilities;

interface

uses
  System.SysUtils, System.Math;

type
  MathUtilities = class
  public
    class function PrincArg(Angle: Double): Double; static;
    class procedure AdaptiveThreshold(var Data: TArray<Double>); static;
    class function Median(const Data: TArray<Double>): Double; static;
    class function Mean(const Data: TArray<Double>): Double; overload; static;
    class function Mean(const Data: TArray<Double>; AStart, ACount: Integer): Double; overload; static;
    class function StdDev(const Data: TArray<Double>): Double; static;
    class procedure Normalize(var Data: TArray<Double>); static;
    class function NextPowerOfTwo(x: Integer): Integer; static;
    class procedure QuickSort(var A: TArray<Double>; iLo, iHi: Integer); static;
  end;

implementation

{ MathUtilities }

class function MathUtilities.NextPowerOfTwo(x: Integer): Integer;
begin
  Result := 1;
  while Result < x do
    Result := Result shl 1;
end;

class function MathUtilities.PrincArg(Angle: Double): Double;
begin
  Result := Angle;
  while Result > Pi do
    Result := Result - 2 * Pi;
  while Result < -Pi do
    Result := Result + 2 * Pi;
end;

class procedure MathUtilities.QuickSort(var A: TArray<Double>; iLo, iHi: Integer);
var
  Lo, Hi: Integer;
  Pivot, T: Double;
begin
  Lo := iLo;
  Hi := iHi;
  Pivot := A[(Lo + Hi) div 2];

  repeat
    while A[Lo] < Pivot do Inc(Lo);
    while A[Hi] > Pivot do Dec(Hi);

    if Lo <= Hi then
    begin
      T := A[Lo];
      A[Lo] := A[Hi];
      A[Hi] := T;
      Inc(Lo);
      Dec(Hi);
    end;
  until Lo > Hi;

  if Hi > iLo then QuickSort(A, iLo, Hi);
  if Lo < iHi then QuickSort(A, Lo, iHi);
end;

class function MathUtilities.Median(const Data: TArray<Double>): Double;
var
  sorted: TArray<Double>;
  mid: Integer;
begin
  if Length(Data) = 0 then
  begin
    Result := 0;
    Exit;
  end;

  // Copiar datos
  sorted := Copy(Data);

  // Ordenar usando QuickSort
  QuickSort(sorted, 0, Length(sorted) - 1);

  mid := Length(sorted) div 2;
  if Length(sorted) mod 2 = 0 then
    Result := (sorted[mid - 1] + sorted[mid]) / 2
  else
    Result := sorted[mid];
end;

class function MathUtilities.Mean(const Data: TArray<Double>): Double;
var
  i: Integer;
begin
  Result := 0;
  if Length(Data) = 0 then Exit;

  for i := 0 to High(Data) do
    Result := Result + Data[i];
  Result := Result / Length(Data);
end;

// Versión sobrecargada de Mean para calcular media de una sección
class function MathUtilities.Mean(const Data: TArray<Double>; AStart, ACount: Integer): Double;
var
  i: Integer;
  sum: Double;
begin
  Result := 0;
  if (ACount = 0) or (AStart < 0) or (AStart + ACount > Length(Data)) then
    Exit;

  sum := 0;
  for i := 0 to ACount - 1 do
    sum := sum + Data[AStart + i];

  Result := sum / ACount;
end;

class function MathUtilities.StdDev(const Data: TArray<Double>): Double;
var
  i: Integer;
  meanVal: Double;
begin
  if Length(Data) < 2 then
  begin
    Result := 0;
    Exit;
  end;

  meanVal := Mean(Data);
  Result := 0;
  for i := 0 to High(Data) do
    Result := Result + Sqr(Data[i] - meanVal);
  Result := Sqrt(Result / Length(Data));
end;

// ============================================================================
// AdaptiveThreshold: Implementación correcta de Mixxx/QM-DSP
// Resta una versión suavizada de la señal original
// ============================================================================
class procedure MathUtilities.AdaptiveThreshold(var Data: TArray<Double>);
var
  i, first, last, sz: Integer;
  smoothed: TArray<Double>;
  p_pre, p_post: Integer;
begin
  sz := Length(Data);
  if sz = 0 then Exit;

  SetLength(smoothed, sz);

  // Parámetros de ventana de Mixxx/QM-DSP
  // Esta es la ventana asimétrica usada por Mixxx
  p_pre := 8;   // 8 muestras hacia atrás
  p_post := 7;  // 7 muestras hacia adelante

  // Calcular versión suavizada (media móvil con ventana asimétrica)
  for i := 0 to sz - 1 do
  begin
    first := Max(0, i - p_pre);
    last := Min(sz - 1, i + p_post);
    // Usar la función Mean sobrecargada
    smoothed[i] := Mean(Data, first, last - first + 1);
  end;

  // Restar versión suavizada y fijar en 0 los valores negativos
  for i := 0 to sz - 1 do
  begin
    Data[i] := Data[i] - smoothed[i];
    if Data[i] < 0.0 then
      Data[i] := 0.0;
  end;
end;

class procedure MathUtilities.Normalize(var Data: TArray<Double>);
var
  i: Integer;
  maxVal: Double;
begin
  if Length(Data) = 0 then Exit;

  maxVal := 0;
  for i := 0 to High(Data) do
    if Abs(Data[i]) > maxVal then
      maxVal := Abs(Data[i]);

  if maxVal > 0 then
    for i := 0 to High(Data) do
      Data[i] := Data[i] / maxVal;
end;

end.