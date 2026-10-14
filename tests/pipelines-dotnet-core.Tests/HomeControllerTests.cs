using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using pipelines_dotnet_core.Controllers;
using pipelines_dotnet_core.Models;
using Xunit;

namespace pipelines_dotnet_core.Tests
{
    // Unit tests: call the controller directly, no web server involved.
    public class HomeControllerTests
    {
        [Fact]
        public void Index_ReturnsView()
        {
            var result = new HomeController().Index();

            Assert.IsType<ViewResult>(result);
        }

        [Fact]
        public void Privacy_ReturnsView()
        {
            var result = new HomeController().Privacy();

            Assert.IsType<ViewResult>(result);
        }

        [Fact]
        public void Error_ExposesRequestIdForSupport()
        {
            var httpContext = new DefaultHttpContext { TraceIdentifier = "trace-123" };
            var controller = new HomeController
            {
                ControllerContext = new ControllerContext { HttpContext = httpContext }
            };

            var view = Assert.IsType<ViewResult>(controller.Error());
            var model = Assert.IsType<ErrorViewModel>(view.Model);

            Assert.False(string.IsNullOrEmpty(model.RequestId));
            Assert.True(model.ShowRequestId);
        }
    }
}
