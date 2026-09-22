namespace SecondDisplay.Host;

/// <summary>
/// Global single-instance guard: a future orchestrator and the manual streaming path
/// must not both run at once (both would try to bind port 27315 / toggle the VDD).
/// </summary>
public sealed class SingleInstance : IDisposable
{
    private readonly Mutex _mutex;
    private bool _disposed;

    private SingleInstance(Mutex mutex)
    {
        _mutex = mutex;
    }

    /// <summary>Returns null if another instance already holds it. Otherwise returns a token to keep alive.</summary>
    public static SingleInstance? TryAcquire(string name = "Global\\SecondDisplayHost")
    {
        var mutex = new Mutex(initiallyOwned: true, name, out bool createdNew);
        if (!createdNew)
        {
            mutex.Dispose();
            return null;
        }
        return new SingleInstance(mutex);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _mutex.ReleaseMutex();
        _mutex.Dispose();
    }
}
