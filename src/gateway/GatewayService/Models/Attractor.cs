using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace GatewayService.Models;

[Table("attractors")]
public class Attractor {
	[Key]
	[Column("id")]
	public string Id { get; set; } = Guid.NewGuid().ToString();

	[Required]
	[Column("formula_latex")]
	public string FormulaLatex { get; set; } = string.Empty;

	[Column("r_squared")]
	public float RSquared { get; set; }

	[Column("is_stable")]
	public bool IsStable { get; set; }

	[Column("created_at")]
	public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
}

