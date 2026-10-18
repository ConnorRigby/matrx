defmodule Matrx.Media do
  @moduledoc """
  Uploading files and building the `m.image`, `m.video`, `m.audio` and `m.file`
  message contents for them.

  In an encrypted room the file is encrypted before it is uploaded (AES-256-CTR,
  as in the spec's `EncryptedFile`), and the content carries `file` with the key
  instead of `url`.

  https://spec.matrix.org/v1.19/client-server-api/#mroommessage-msgtypes
  """

  @type upload_opts :: [
          content_type: String.t(),
          caption: String.t(),
          info: map(),
          encrypt: boolean(),
          api: module()
        ]

  @doc """
  Upload `data` and build the message content for it.

  Options:
  * `:content_type`: the MIME type. Guessed from the filename's extension by default.
  * `:caption`: text shown with the file. The filename is the body by default.
  * `:info`: merged over the `info` map, which has `mimetype` and `size`. Use it
    for `w`, `h`, `duration` and so on, which are not detected.
  * `:encrypt`: encrypt the file before uploading it. Default `false`.
  * `:api`
  """
  @spec upload(Matrx.Session.t(), binary(), String.t(), upload_opts()) ::
          {:ok, map()} | {:error, term()}
  def upload(session, data, filename, opts \\ []) when is_binary(data) and is_binary(filename) do
    api = Keyword.get(opts, :api, Matrx.API)
    content_type = Keyword.get_lazy(opts, :content_type, fn -> content_type(filename) end)

    info =
      %{"mimetype" => content_type, "size" => byte_size(data)}
      |> Map.merge(Keyword.get(opts, :info, %{}))

    {payload, file, upload_type} =
      if Keyword.get(opts, :encrypt, false) do
        {ciphertext, file} = encrypt(data)
        {ciphertext, file, "application/octet-stream"}
      else
        {data, nil, content_type}
      end

    with {:ok, %{content_uri: uri}} <- api.upload_media(session, payload, upload_type, filename) do
      {:ok,
       %{
         "msgtype" => msgtype(content_type),
         "body" => Keyword.get(opts, :caption, filename),
         "info" => info
       }
       |> put_filename(filename, opts)
       |> put_source(uri, file)}
    end
  end

  @doc "The MIME type for a filename's extension, `application/octet-stream` if unknown"
  @spec content_type(String.t()) :: String.t()
  def content_type(filename), do: MIME.from_path(filename)

  @doc "The `msgtype` used for a MIME type"
  @spec msgtype(String.t()) :: String.t()
  def msgtype("image/" <> _), do: "m.image"
  def msgtype("video/" <> _), do: "m.video"
  def msgtype("audio/" <> _), do: "m.audio"
  def msgtype(_), do: "m.file"

  @doc "Encrypt `data` for an encrypted room. Returns the ciphertext and the `EncryptedFile` fields without `url`."
  @spec encrypt(binary()) :: {binary(), map()}
  def encrypt(data) do
    key = :crypto.strong_rand_bytes(32)
    # The counter is the low 8 bytes, which must start at zero
    iv = :crypto.strong_rand_bytes(8) <> <<0::64>>
    ciphertext = :crypto.crypto_one_time(:aes_256_ctr, key, iv, data, true)

    file = %{
      "v" => "v2",
      "key" => %{
        "kty" => "oct",
        "key_ops" => ["encrypt", "decrypt"],
        "alg" => "A256CTR",
        "k" => Base.url_encode64(key, padding: false),
        "ext" => true
      },
      "iv" => Base.encode64(iv, padding: false),
      "hashes" => %{"sha256" => Base.encode64(:crypto.hash(:sha256, ciphertext), padding: false)}
    }

    {ciphertext, file}
  end

  @doc "Check and decrypt a downloaded file with the `file` map from a message's content"
  @spec decrypt(binary(), map()) :: {:ok, binary()} | {:error, :hash_mismatch | :invalid_file}
  def decrypt(ciphertext, %{"key" => %{"k" => k}, "iv" => iv, "hashes" => %{"sha256" => hash}}) do
    with {:ok, key} <- Base.url_decode64(k, padding: false),
         {:ok, iv} <- Base.decode64(iv, padding: false),
         {:ok, expected} <- Base.decode64(hash, padding: false) do
      if :crypto.hash_equals(:crypto.hash(:sha256, ciphertext), expected) do
        {:ok, :crypto.crypto_one_time(:aes_256_ctr, key, iv, ciphertext, false)}
      else
        {:error, :hash_mismatch}
      end
    else
      _ -> {:error, :invalid_file}
    end
  end

  def decrypt(_ciphertext, _file), do: {:error, :invalid_file}

  # With a caption the body is the caption and the filename goes in its own field
  defp put_filename(content, filename, opts) do
    if Keyword.has_key?(opts, :caption),
      do: Map.put(content, "filename", filename),
      else: content
  end

  defp put_source(content, uri, nil), do: Map.put(content, "url", uri)
  defp put_source(content, uri, file), do: Map.put(content, "file", Map.put(file, "url", uri))
end
