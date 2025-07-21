defmodule VsmExternalInterfaces.Adapters.HTTPTest do
  use ExUnit.Case, async: true
  use Plug.Test
  
  alias VsmExternalInterfaces.Adapters.HTTP
  
  @opts HTTP.init([])
  
  describe "health endpoint" do
    test "returns health status" do
      conn = conn(:get, "/health")
      conn = HTTP.call(conn, @opts)
      
      assert conn.state == :sent
      assert conn.status == 200
      
      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["status"] == "healthy"
      assert Map.has_key?(response, "timestamp")
      assert Map.has_key?(response, "adapters")
    end
  end
  
  describe "systems endpoint" do
    test "GET /systems returns list of systems" do
      conn = conn(:get, "/systems")
      conn = HTTP.call(conn, @opts)
      
      assert conn.state == :sent
      assert conn.status == 200
      
      {:ok, response} = Jason.decode(conn.resp_body)
      assert Map.has_key?(response, "systems")
      assert is_list(response["systems"])
    end
    
    test "GET /systems/:id returns specific system" do
      conn = conn(:get, "/systems/manufacturing_plant_1")
      conn = HTTP.call(conn, @opts)
      
      # Should return 200 for mock system
      assert conn.state == :sent
      assert conn.status == 200
    end
    
    test "GET /systems/:id returns 404 for unknown system" do
      conn = conn(:get, "/systems/unknown_system")
      conn = HTTP.call(conn, @opts)
      
      assert conn.state == :sent
      assert conn.status == 404
    end
  end
  
  describe "message sending" do
    test "POST /systems/:id/messages with valid message" do
      message = %{
        "type" => "command",
        "channel" => "temporal",
        "payload" => %{"action" => "start"}
      }
      
      conn = conn(:post, "/systems/manufacturing_plant_1/messages", Jason.encode!(message))
      conn = put_req_header(conn, "content-type", "application/json")
      conn = HTTP.call(conn, @opts)
      
      assert conn.state == :sent
      assert conn.status == 201
      
      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["status"] == "sent"
      assert Map.has_key?(response, "message_id")
    end
    
    test "POST /systems/:id/messages with invalid message returns 400" do
      invalid_message = %{
        "invalid" => "message"
      }
      
      conn = conn(:post, "/systems/manufacturing_plant_1/messages", Jason.encode!(invalid_message))
      conn = put_req_header(conn, "content-type", "application/json")
      conn = HTTP.call(conn, @opts)
      
      assert conn.state == :sent
      assert conn.status == 400
    end
  end
  
  describe "algedonic alerts" do
    test "POST /algedonic/alert with valid alert" do
      alert = %{
        "message" => "Critical failure",
        "source" => "sensor_1",
        "severity" => "critical"
      }
      
      conn = conn(:post, "/algedonic/alert", Jason.encode!(alert))
      conn = put_req_header(conn, "content-type", "application/json")
      conn = HTTP.call(conn, @opts)
      
      assert conn.state == :sent
      assert conn.status == 201
      
      {:ok, response} = Jason.decode(conn.resp_body)
      assert response["status"] == "triggered"
      assert Map.has_key?(response, "alert_id")
    end
  end
  
  describe "error handling" do
    test "unknown endpoint returns 404" do
      conn = conn(:get, "/unknown")
      conn = HTTP.call(conn, @opts)
      
      assert conn.state == :sent
      assert conn.status == 404
    end
    
    test "invalid JSON returns 400" do
      conn = conn(:post, "/systems/test/messages", "invalid json")
      conn = put_req_header(conn, "content-type", "application/json")
      conn = HTTP.call(conn, @opts)
      
      assert conn.state == :sent
      assert conn.status == 400
    end
  end
end