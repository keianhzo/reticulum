defmodule Ret.TwitterClient do
  import Ret.HttpUtils

  @twitter_api_base "https://api.twitter.com"
  @twitter_upload_api_base "https://upload.twitter.com"

  alias Ret.{Account, OwnedFile, Storage}

  def get_oauth_url(hub_sid, account_id) do
    creds =
      OAuther.credentials(
        consumer_key: module_config(:consumer_key),
        consumer_secret: module_config(:consumer_secret),
        token: module_config(:access_token),
        token_secret: module_config(:access_token_secret)
      )

    token = Ret.OAuthToken.token_for_hub_and_account(hub_sid, account_id)
    callback_url = "#{get_redirect_uri()}?state=#{token}"
    res = post("#{@twitter_api_base}/oauth/request_token", [{"oauth_callback", callback_url}], creds)
    "#{@twitter_api_base}/oauth/authorize?" <> URI.encode_query(%{oauth_token: res["oauth_token"]})
  end

  def get_access_token_and_user_info(oauth_verifier, request_token) do
    creds =
      OAuther.credentials(
        consumer_key: module_config(:consumer_key),
        consumer_secret: module_config(:consumer_secret),
        token: request_token
      )

    post("#{@twitter_api_base}/oauth/access_token", [{"oauth_verifier", oauth_verifier}], creds)
  end

  def upload_stored_file_as_media(stored_file_uuid, stored_file_access_token, account) do
    oauth_provider = Account.oauth_provider_for_source(account, :twitter)
    url = "#{@twitter_upload_api_base}/1.1/media/upload.json"

    creds =
      OAuther.credentials(
        consumer_key: module_config(:consumer_key),
        consumer_secret: module_config(:consumer_secret),
        token: oauth_provider.provider_access_token,
        token_secret: oauth_provider.provider_access_token_secret
      )

    storage_result =
      case OwnedFile.get_by_uuid_and_account(stored_file_uuid, account.account_id) do
        %OwnedFile{} = owned_file ->
          Storage.fetch(owned_file)

        _ ->
          Storage.fetch(stored_file_uuid, stored_file_access_token)
      end

    wait_for_finished = fn media_id, iteration ->
      if iteration < 10 do
        status = get(url, [{"command", "STATUS"}, {"media_id", media_id}], creds)

        if status["progress_percent"] != 100 do
          wait_for_finished.(media_id, iteration + 1)
        else
          media_id
        end
      else
        nil
      end
    end

    case storage_result do
      {:ok, %{"content_length" => total_bytes, "content_type" => media_type}, stream} ->
        media_init_res =
          post(
            url,
            [
              {"command", "INIT"},
              {"total_bytes", total_bytes},
              {"media_type", media_type},
              {"media_category", "tweet_video"}
            ],
            creds,
            :json
          )

        case media_init_res do
          %{"media_id_string" => media_id} ->
            upload_media_chunks(creds, stream, media_id)
            post(url, [{"command", "FINALIZE"}, {"media_id", media_id}], creds, :json)

            wait_for_finished.(media_id, 0)

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  def tweet(body, account, media_id \\ nil) do
    url = "#{@twitter_api_base}/1.1/statuses/update.json"
    oauth_provider = Account.oauth_provider_for_source(account, :twitter)

    creds =
      OAuther.credentials(
        consumer_key: module_config(:consumer_key),
        consumer_secret: module_config(:consumer_secret),
        token: oauth_provider.provider_access_token,
        token_secret: oauth_provider.provider_access_token_secret
      )

    post(url, [{"status", body}, {"media_ids", "#{media_id}"}], creds, :json)
  end

  defp post(url, params, creds, response_type \\ :urlencoded, cap_ms \\ 5_000, expiry_ms \\ 10_000) do
    params = OAuther.sign("post", url, params, creds)
    encoded_params = URI.encode_query(params)

    body =
      retry_post_until_success(
        url,
        encoded_params,
        [{"content-type", "application/x-www-form-urlencoded"}],
        cap_ms,
        expiry_ms
      )
      |> Map.get(:body)
      |> to_string

    case response_type do
      :urlencoded -> body |> URI.decode_query()
      :json -> body |> Poison.decode!()
      _ -> body
    end
  end

  defp upload_media_chunks(creds, stream, media_id) do
    Enum.reduce(stream, 0, fn chunk, chunk_idx ->
      post(
        "#{@twitter_upload_api_base}/1.1/media/upload.json",
        [
          {"command", "APPEND"},
          {"media_id", media_id},
          {"media_data", Base.encode64(chunk)},
          {"segment_index", chunk_idx}
        ],
        creds,
        :text,
        60_000,
        120_000
      )

      chunk_idx + 1
    end)
  end

  defp get_redirect_uri(), do: RetWeb.Endpoint.url() <> "/api/v1/oauth/twitter"

  defp get(url, params, creds) do
    oauther_params = OAuther.sign("get", url, params, creds)
    encoded_params = URI.encode_query(oauther_params)
    request_url = "#{url}?#{encoded_params}"

    retry_get_until_success(request_url)
    |> Map.get(:body)
    |> Poison.decode!()
  end

  defp module_config(key) do
    Application.get_env(:ret, __MODULE__)[key]
  end
end
