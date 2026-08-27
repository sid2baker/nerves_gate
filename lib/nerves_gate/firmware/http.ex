defmodule NervesGate.Firmware.HTTP do
  @moduledoc "Bounded HTTP reads and resumable, back-pressured downloads using OTP httpc."

  @default_timeout 30_000
  @progress_step 1024 * 1024

  @spec get(String.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, binary()} | {:error, term()}
  def get(url, headers \\ [], options \\ []) do
    maximum = Keyword.get(options, :maximum_size, 1024 * 1024)

    with :ok <- validate_url(url, options),
         {:ok, request_id} <- request(url, headers, options),
         {:ok, _headers, body} <- collect(request_id, <<>>, maximum, options) do
      {:ok, body}
    end
  end

  @spec download(String.t(), Path.t(), pos_integer(), (non_neg_integer() -> any()), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def download(url, partial_path, expected_size, progress \\ fn _bytes -> :ok end, options \\ [])
      when is_binary(partial_path) and is_integer(expected_size) and expected_size > 0 and
             is_function(progress, 1) do
    with :ok <- validate_url(url, options),
         :ok <- File.mkdir_p(Path.dirname(partial_path)),
         {:ok, offset} <- resumable_offset(partial_path, expected_size),
         headers <- range_header(offset),
         {:ok, request_id} <- request(url, headers, options) do
      receive_download(request_id, partial_path, offset, expected_size, progress, options)
    end
  end

  defp request(url, headers, options) do
    request = {String.to_charlist(url), request_headers(headers)}
    timeout = Keyword.get(options, :timeout, @default_timeout)

    http_options = [
      timeout: timeout,
      connect_timeout: min(timeout, 15_000),
      autoredirect: true,
      ssl: :httpc.ssl_verify_host_options(true)
    ]

    :httpc.request(:get, request, http_options,
      sync: false,
      stream: {:self, :once},
      receiver: self()
    )
  end

  defp collect(request_id, body, maximum, options) do
    timeout = Keyword.get(options, :timeout, @default_timeout)

    receive do
      {:http, {^request_id, :stream_start, headers, handler}} ->
        :httpc.stream_next(handler)
        collect_stream(request_id, handler, headers, body, maximum, timeout)

      {:http, {^request_id, {{_version, status, _reason}, _headers, response_body}}} ->
        if status in 200..299,
          do: bounded_body(response_body, maximum),
          else: {:error, {:http, status}}

      {:http, {^request_id, {:error, reason}}} ->
        {:error, {:http, reason}}
    after
      timeout ->
        cancel(request_id)
        {:error, :download_timeout}
    end
  end

  defp collect_stream(request_id, handler, headers, body, maximum, timeout) do
    receive do
      {:http, {^request_id, :stream, chunk}} ->
        size = byte_size(body) + byte_size(chunk)

        if size <= maximum do
          :httpc.stream_next(handler)
          collect_stream(request_id, handler, headers, body <> chunk, maximum, timeout)
        else
          cancel(request_id)
          {:error, :response_too_large}
        end

      {:http, {^request_id, :stream_end, _trailers}} ->
        {:ok, headers, body}

      {:http, {^request_id, {:error, reason}}} ->
        {:error, {:http, reason}}
    after
      timeout ->
        cancel(request_id)
        {:error, :download_timeout}
    end
  end

  defp bounded_body(body, maximum) when is_list(body),
    do: bounded_body(IO.iodata_to_binary(body), maximum)

  defp bounded_body(body, maximum) when byte_size(body) <= maximum, do: {:ok, [], body}
  defp bounded_body(_body, _maximum), do: {:error, :response_too_large}

  defp receive_download(request_id, path, offset, expected_size, progress, options) do
    timeout = Keyword.get(options, :timeout, @default_timeout)

    receive do
      {:http, {^request_id, :stream_start, headers, handler}} ->
        with {:ok, mode, bytes} <- download_mode(headers, offset),
             {:ok, file} <- open_download(path, mode) do
          progress.(bytes)
          :httpc.stream_next(handler)
          stream_file(request_id, handler, file, bytes, bytes, expected_size, progress, timeout)
        end

      {:http, {^request_id, {{_version, status, _reason}, _headers, _body}}} ->
        {:error, {:http, status}}

      {:http, {^request_id, {:error, reason}}} ->
        {:error, {:http, reason}}
    after
      timeout ->
        cancel(request_id)
        {:error, :download_timeout}
    end
  end

  defp stream_file(request_id, handler, file, bytes, reported, expected, progress, timeout) do
    receive do
      {:http, {^request_id, :stream, chunk}} ->
        next = bytes + byte_size(chunk)

        cond do
          next > expected ->
            cancel(request_id)
            close(file)
            {:error, :artifact_too_large}

          :file.write(file, chunk) != :ok ->
            cancel(request_id)
            close(file)
            {:error, :artifact_write_failed}

          true ->
            reported = report_progress(progress, next, reported)
            :httpc.stream_next(handler)
            stream_file(request_id, handler, file, next, reported, expected, progress, timeout)
        end

      {:http, {^request_id, :stream_end, _trailers}} ->
        result = finish_file(file, bytes, expected)
        if result == {:ok, expected}, do: progress.(expected)
        result

      {:http, {^request_id, {:error, reason}}} ->
        close(file)
        {:error, {:http, reason}}
    after
      timeout ->
        cancel(request_id)
        close(file)
        {:error, :download_timeout}
    end
  end

  defp download_mode(_headers, 0), do: {:ok, :replace, 0}

  defp download_mode(headers, offset) do
    case header(headers, "content-range") do
      nil ->
        {:ok, :replace, 0}

      value ->
        if range_starts_at?(value, offset),
          do: {:ok, :append, offset},
          else: {:error, :invalid_content_range}
    end
  end

  defp open_download(path, :replace),
    do: :file.open(String.to_charlist(path), [:raw, :binary, :write])

  defp open_download(path, :append),
    do: :file.open(String.to_charlist(path), [:raw, :binary, :append])

  defp finish_file(file, bytes, expected) do
    result = if bytes == expected, do: :file.sync(file), else: {:error, :artifact_size_mismatch}
    close(file)

    case result do
      :ok -> {:ok, bytes}
      {:error, _reason} = error -> error
    end
  end

  defp close(file) do
    :file.close(file)
    :ok
  end

  defp report_progress(progress, bytes, reported) when bytes - reported >= @progress_step do
    progress.(bytes)
    bytes
  end

  defp report_progress(_progress, _bytes, reported), do: reported

  defp resumable_offset(path, expected_size) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= expected_size -> {:ok, size}
      {:ok, _oversized} -> with :ok <- File.rm(path), do: {:ok, 0}
      {:error, :enoent} -> {:ok, 0}
      {:error, reason} -> {:error, {:artifact_stat_failed, reason}}
    end
  end

  defp range_header(0), do: []
  defp range_header(offset), do: [{"range", "bytes=#{offset}-"}]

  defp request_headers(headers) do
    [{"user-agent", "NervesGate firmware updater"} | headers]
    |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp header(headers, wanted) do
    Enum.find_value(headers, fn {key, value} ->
      if key |> to_string() |> String.downcase() == wanted, do: to_string(value)
    end)
  end

  defp range_starts_at?(value, offset) do
    String.starts_with?(value, "bytes #{offset}-")
  end

  defp validate_url(url, options) do
    allow_http = Keyword.get(options, :allow_insecure_http, false)

    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) -> :ok
      %URI{scheme: "http", host: host} when is_binary(host) and allow_http -> :ok
      _invalid -> {:error, :unsafe_release_url}
    end
  end

  defp cancel(request_id) do
    :httpc.cancel_request(request_id)
    :ok
  end
end
