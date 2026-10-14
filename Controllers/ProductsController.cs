using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace pipelines_dotnet_core.Controllers
{
    // DEMO ONLY: deliberately vulnerable to show the SAST gate blocking a pull request.
    public class ProductsController : Controller
    {
        public IActionResult Search(string name)
        {
            using var conn = new SqlConnection("Server=db;Database=shop;Integrated Security=true");
            conn.Open();
            var cmd = new SqlCommand("SELECT * FROM Products WHERE Name = '" + name + "'", conn);
            using var reader = cmd.ExecuteReader();
            return Ok();
        }
    }
}
