defmodule Bumblebee.Text.ZeroShotClassification do
  @moduledoc false

  alias Bumblebee.Utils
  alias Bumblebee.Shared

  def zero_shot_classification(model_info, tokenizer, labels, opts \\ []) do
    %{model: model, params: params, spec: spec} = model_info
    Shared.validate_architecture!(spec, :for_sequence_classification)

    opts =
      Keyword.validate!(opts, [
        :compile,
        hypothesis_template: &default_hypothesis_template/1,
        top_k: 5,
        defn_options: []
      ])

    hypothesis_template = opts[:hypothesis_template]
    top_k = opts[:top_k]
    compile = opts[:compile]
    defn_options = opts[:defn_options]

    hypotheses = Enum.map(labels, hypothesis_template)

    sequences_per_batch = length(labels)

    sequence_length = compile[:sequence_length]
    batch_size = compile[:batch_size]

    if compile != nil and (batch_size == nil or sequence_length == nil) do
      raise ArgumentError,
            "expected :compile to be a keyword list specifying :batch_size and :sequence_length, got: #{inspect(compile)}"
    end

    entailment_id =
      Enum.find_value(spec.id_to_label, fn {id, label} ->
        label == "entailment" && id
      end)

    unless entailment_id do
      raise ArgumentError,
            ~s/expected model specification to include "entailment" label in :id_to_label/
    end

    {_init_fun, predict_fun} = Axon.build(model)

    scores_fun = fn params, input ->
      input = Utils.Nx.composite_flatten_batch(input)
      %{logits: logits} = predict_fun.(params, input)
      logits
    end

    Nx.Serving.new(
      fn ->
        scores_fun =
          Shared.compile_or_jit(scores_fun, defn_options, compile != nil, fn ->
            inputs = %{
              "input_ids" =>
                Nx.template({batch_size, sequences_per_batch, sequence_length}, :s64),
              "attention_mask" =>
                Nx.template({batch_size, sequences_per_batch, sequence_length}, :s64)
            }

            [params, inputs]
          end)

        fn inputs ->
          inputs = Shared.maybe_pad(inputs, batch_size)
          scores = scores_fun.(params, inputs)
          Utils.Nx.composite_unflatten_batch(scores, inputs.size)
        end
      end,
      batch_size: batch_size
    )
    |> Nx.Serving.client_preprocessing(fn input ->
      {texts, multi?} = Shared.validate_serving_input!(input, &Shared.validate_string/1)

      pairs = for text <- texts, hypothesis <- hypotheses, do: {text, hypothesis}

      inputs =
        Bumblebee.apply_tokenizer(tokenizer, pairs,
          length: sequence_length,
          return_token_type_ids: false
        )

      inputs = Utils.Nx.composite_unflatten_batch(inputs, length(texts))

      {Nx.Batch.concatenate([inputs]), multi?}
    end)
    |> Nx.Serving.client_postprocessing(fn scores, _metadata, multi? ->
      for scores <- Utils.Nx.batch_to_list(scores) do
        scores = Axon.Layers.softmax(scores[[0..-1//1, entailment_id]])

        k = min(top_k, Nx.size(scores))
        {top_scores, top_indices} = Utils.Nx.top_k(scores, k: k)

        predictions =
          Enum.zip_with(
            Nx.to_flat_list(top_scores),
            Nx.to_flat_list(top_indices),
            fn score, idx ->
              label = Enum.at(labels, idx)
              %{score: score, label: label}
            end
          )

        %{predictions: predictions}
      end
      |> Shared.normalize_output(multi?)
    end)
  end

  defp default_hypothesis_template(label), do: "This example is #{label}."
end
