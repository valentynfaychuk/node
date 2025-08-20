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

    :ok = :gen_udp.send(socket, 'stun.l.google.com', 19302, req)
    {:ok, {_, _, resp}} = :gen_udp.recv(socket, 0)

    {:ok, msg} = Message.decode(resp)
    {:ok, %{address: address}} = Message.get_attribute(msg, XORMappedAddress)
    address
  end
end
