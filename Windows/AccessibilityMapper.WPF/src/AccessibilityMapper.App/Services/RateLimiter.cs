namespace AccessibilityMapper.App.Services;

/// <summary>
/// Serialises callers and enforces a minimum gap between them. Used to hold the app to the
/// Nominatim usage policy's absolute cap of 1 request per second.
/// </summary>
public sealed class RateLimiter(TimeSpan minimumInterval)
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private DateTimeOffset _last = DateTimeOffset.MinValue;

    /// <summary>
    /// Returns once it is this caller's turn and the minimum interval has elapsed. The gate
    /// is held across the delay on purpose: that is what stops two concurrent searches from
    /// both deciding they are clear to go.
    /// </summary>
    public async Task WaitAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var remaining = _last + minimumInterval - DateTimeOffset.UtcNow;
            if (remaining > TimeSpan.Zero)
                await Task.Delay(remaining, cancellationToken);

            _last = DateTimeOffset.UtcNow;
        }
        finally
        {
            _gate.Release();
        }
    }
}
