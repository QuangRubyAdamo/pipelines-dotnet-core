using System.Net;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Mvc.Testing;
using Xunit;

namespace pipelines_dotnet_core.Tests
{
    // Integration tests: start the real app in memory and call it over HTTP,
    // the same way the deploy health check and users reach it.
    public class EndpointTests : IClassFixture<WebApplicationFactory<Startup>>
    {
        private readonly WebApplicationFactory<Startup> _factory;

        public EndpointTests(WebApplicationFactory<Startup> factory)
        {
            _factory = factory;
        }

        [Fact]
        public async Task Health_ReturnsHealthy()
        {
            var response = await _factory.CreateClient().GetAsync("/health");

            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            Assert.Equal("Healthy", await response.Content.ReadAsStringAsync());
        }

        [Theory]
        [InlineData("/", "A lifetime of care")]
        [InlineData("/Home/Privacy", "Privacy Policy")]
        public async Task Pages_RenderTheirContent(string url, string expectedText)
        {
            var response = await _factory.CreateClient().GetAsync(url);

            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            Assert.Contains(expectedText, await response.Content.ReadAsStringAsync());
        }

        [Fact]
        public async Task Home_IsLabelledAsConceptAndCompatibleWithTheSiteCsp()
        {
            var html = await _factory.CreateClient().GetStringAsync("/");

            // The concept must never pass for the official Raffles site or be indexed.
            Assert.Contains("Concept demo by Adamo", html);
            Assert.Contains("<meta name=\"robots\" content=\"noindex, nofollow\">", html);
            // The Content-Security-Policy allows no inline styles and no data: stylesheets,
            // so styles, scripts and photos must come from files.
            Assert.DoesNotContain(" style=\"", html);
            Assert.DoesNotContain("<style", html);
            Assert.DoesNotContain("data:image", html);
        }

        [Fact]
        public async Task UnknownPage_ReturnsNotFound()
        {
            var response = await _factory.CreateClient().GetAsync("/does-not-exist");

            Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
        }
    }
}
