using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace PodNet.Nugetizer.Fixture.Tests;

[TestClass]
public sealed class ValueTests
{
    [TestMethod]
    public void FixtureRuns() => Assert.AreEqual(42, Value.Answer);
}