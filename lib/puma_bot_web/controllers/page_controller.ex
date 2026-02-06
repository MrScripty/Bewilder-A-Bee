defmodule PumaBotWeb.PageController do
  use PumaBotWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
