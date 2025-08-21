defmodule STUN do
  alias ExSTUN.Message
  alias ExSTUN.Message.Type
  alias ExSTUN.Message.Attribute.XORMappedAddress

  def get_my_public_ipv4() do
    {:ok, socket} = :gen_udp.open(0, [{:active, false}, :binary])

    req =
      %Type{class: :request, method: :binding}
      |> Message.new()
      |> Message.encode()

    :ok = :gen_udp.send(socket, ~c'stun.l.google.com', 19302, req)
    {:ok, {_, _, resp}} = :gen_udp.recv(socket, 0, 6000)

    {:ok, msg} = Message.decode(resp)
    {:ok, %{address: {ip1,ip2,ip3,ip4}}} = Message.get_attribute(msg, XORMappedAddress)
    "#{ip1}.#{ip2}.#{ip3}.#{ip4}"
  end

  def get_my_public_ipv4_http() do
    url = "http://api.myip.la/en?json"
    {:ok, %{status_code: 200, body: body}} = :comsat_http.get(url, %{}, %{timeout: 6000})
    JSX.decode!(body, labels: :atom).ip
  end

  def get_current_ip4() do
    pub_ipv4 = case System.get_env("PUBLIC_UDP_IPV4") do
      nil -> get_current_ip4_2()
      ipv4 -> ipv4
    end
  end
  defp get_current_ip4_2() do
    IO.puts "trying to get ip4 via STUN.."
    ip4 = try do get_my_public_ipv4() catch _,_ -> nil end
    if ip4 do ip4 else
      IO.puts "trying to get ip4 via HTTP.."
      ip4 = try do get_my_public_ipv4_http() catch _,_ -> nil end
      if ip4 do ip4 else
        IO.put "failed to find your nodes public ip. Hardcode it via PUBLIC_UDP_IPV4="
      end
    end
  end
end
