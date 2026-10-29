defmodule PopcornDemo.AzureCost.Line do
  
  @moduledoc """
  One priced line item. `rate` is the fetched record's identity
  (meterName + skuName + retailPrice + unitOfMeasure + fetched_at), so every
  dollar amount = fetched retailPrice x computed quantity, traced to the
  fetched rate card.
  """

  defmodule Rate do
    @moduledoc "One fetched retail rate (raw Retail Prices API record)."
    defstruct [:key, :meter_name, :sku_name, :product_name, :unit,
               :retail_price, :fetched_at]

    @type t :: %__MODULE__{}
  end

  defstruct [:key, :weight, :rate, :qty, :amount, :unit]

  @type t :: %__MODULE__{}

  @doc """
  Build a line. Zero-weight workloads produce a zero line (rate=nil,
  amount=0.0) which price/3 drops from the plan.
  """
  @spec build(atom(), number(), Rate.t() | nil, keyword()) :: t()
  def build(key, weight, rate, opts)

  def build(_key, w, _rate, _opts) when w == 0 or w == 0.0 do
    %__MODULE__{weight: 0, rate: nil, qty: 0.0, amount: 0.0, unit: "unused"}
  end

  def build(key, weight, %Rate{} = rate, opts) when weight > 0 do
    qty = Keyword.fetch!(opts, :qty)
    unit = Keyword.fetch!(opts, :unit)

    %__MODULE__{
      key: key,
      weight: weight,
      rate: rate,
      qty: qty,
      amount: rate.retail_price * qty,
      unit: unit
    }
  end
end
