using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace PodNet.Nugetizer.Fixture.IntegrationTests;

[TestClass]
public sealed class PackageTests
{
    [TestMethod]
    public void ReleasePackageWorks() => Assert.AreEqual(42, Value.Answer);
}