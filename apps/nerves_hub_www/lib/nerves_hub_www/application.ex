defmodule NervesHubWWW.Application do
  use Application

  def start(_type, _args) do
    NervesHubWebCore.CertificateAuthority.start_pool()

    children = [
      NervesHubWWWWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: NervesHubWWW.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def config_change(changed, _new, removed) do
    NervesHubWWWWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
