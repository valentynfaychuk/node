defmodule UDPProbe do
    def test() do
        """
        echo "udp_test" > /dev/udp/127.0.0.1/36969
        """
    end
end