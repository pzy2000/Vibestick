namespace Vibestick.Gui;

public sealed record PetActionFrequencySettings
{
    public const double MinMultiplier = 0.5;
    public const double MaxMultiplier = 2.0;
    public const double Step = 0.1;

    public static PetActionFrequencySettings Default { get; } = new();

    public double RandomActionFrequency { get; init; } = 1.0;
    public double WalkSpeedMultiplier { get; init; } = 1.0;
    public double WanderFrequency { get; init; } = 1.0;

    public PetActionFrequencySettings Clamped()
    {
        return this with
        {
            RandomActionFrequency = ClampMultiplier(RandomActionFrequency),
            WalkSpeedMultiplier = ClampMultiplier(WalkSpeedMultiplier),
            WanderFrequency = ClampMultiplier(WanderFrequency)
        };
    }

    public TimeSpan ScaleRandomActionDelay(TimeSpan delay)
    {
        return ScaleDuration(delay, RandomActionFrequency);
    }

    public double ScaleWalkSpeed(double speed)
    {
        return speed * ClampMultiplier(WalkSpeedMultiplier);
    }

    public TimeSpan ScaleWanderInterval(TimeSpan interval)
    {
        return ScaleDuration(interval, WanderFrequency);
    }

    public static double ClampMultiplier(double value)
    {
        if (double.IsNaN(value) || double.IsInfinity(value))
        {
            return 1.0;
        }

        var snapped = Math.Round(value / Step, MidpointRounding.AwayFromZero) * Step;
        return Math.Min(Math.Max(snapped, MinMultiplier), MaxMultiplier);
    }

    private static TimeSpan ScaleDuration(TimeSpan duration, double multiplier)
    {
        var clamped = ClampMultiplier(multiplier);
        var ticks = Math.Max(1, (long)Math.Round(duration.Ticks / clamped, MidpointRounding.AwayFromZero));
        return TimeSpan.FromTicks(ticks);
    }
}
