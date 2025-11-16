ExUnit.start()

defmodule LoraTest.Helpers do
  def poll_for_child(supervisor, id, retries \\ 10)
  def poll_for_child(_supervisor, _id, 0), do: false

  def poll_for_child(supervisor, id, retries) do
    children = Supervisor.which_children(supervisor)

    if Enum.any?(children, fn {child_id, _, _, _} -> child_id == id end) do
      true
    else
      Process.sleep(100)
      poll_for_child(supervisor, id, retries - 1)
    end
  end

  def wait_for_files(files, timeout_ms \\ 1000) do
    step_interval = 50
    max_attempts = div(timeout_ms, step_interval)

    Enum.reduce_while(1..max_attempts, nil, fn _, _ ->
      if Enum.all?(files, &File.exists?/1) do
        {:halt, :ok}
      else
        Process.sleep(step_interval)
        {:cont, nil}
      end
    end)
  end
end
