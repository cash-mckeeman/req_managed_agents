defmodule ReqManagedAgents.AWS.CredentialsTest do
  use ExUnit.Case, async: false

  setup do
    keys = [:aws_access_key_id, :aws_secret_access_key, :aws_region, :aws_session_token]

    variables = [
      "AWS_ACCESS_KEY_ID",
      "AWS_SECRET_ACCESS_KEY",
      "AWS_REGION",
      "AWS_DEFAULT_REGION",
      "AWS_SESSION_TOKEN"
    ]

    config = Enum.map(keys, &{&1, Application.fetch_env(:req_managed_agents, &1)})
    env = Enum.map(variables, &{&1, System.get_env(&1)})
    Enum.each(keys, &Application.delete_env(:req_managed_agents, &1))
    Enum.each(variables, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(config, fn
        {key, {:ok, value}} -> Application.put_env(:req_managed_agents, key, value)
        {key, :error} -> Application.delete_env(:req_managed_agents, key)
      end)

      Enum.each(env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)
  end

  test "both namespaces preserve opts, app config, environment and region fallback" do
    System.put_env("AWS_ACCESS_KEY_ID", "env-key")
    System.put_env("AWS_SECRET_ACCESS_KEY", "env-secret")
    System.put_env("AWS_SESSION_TOKEN", "env-token")

    for signer <- [ReqManagedAgents.AWS.SigV4, ReqManagedAgents.AgentCore.SigV4] do
      assert %{
               access_key_id: "env-key",
               secret_access_key: "env-secret",
               security_token: "env-token",
               region: "us-east-1"
             } = signer.from_env()

      System.put_env("AWS_DEFAULT_REGION", "us-west-2")
      assert signer.from_env().region == "us-west-2"
      System.put_env("AWS_REGION", "eu-west-1")
      assert signer.from_env().region == "eu-west-1"
      Application.put_env(:req_managed_agents, :aws_access_key_id, "app-key")
      Application.put_env(:req_managed_agents, :aws_region, "ap-south-1")
      assert %{access_key_id: "app-key", region: "ap-south-1"} = signer.from_env()

      assert %{
               access_key_id: "opt-key",
               secret_access_key: "opt-secret",
               security_token: "opt-token",
               region: "us-east-2"
             } =
               signer.from_env(
                 aws_access_key_id: "opt-key",
                 aws_secret_access_key: "opt-secret",
                 aws_session_token: "opt-token",
                 aws_region: "us-east-2"
               )

      Application.delete_env(:req_managed_agents, :aws_access_key_id)
      Application.delete_env(:req_managed_agents, :aws_region)
      System.delete_env("AWS_REGION")
      System.delete_env("AWS_DEFAULT_REGION")
    end
  end
end
