using GatewayService.Models;
using Microsoft.EntityFrameworkCore;

namespace GatewayService.Data;

public class AppDbContext : DbContext {
	public AppDbContext(DbContextOptions<AppDbContext> options) : base(options) { }

	public DbSet<Attractor> Attractors => Set<Attractor>();

	protected override void OnModelCreating(ModelBuilder modelBuilder) {
		base.OnModelCreating(modelBuilder);

		modelBuilder.Entity<Attractor>(entity => {
			entity.ToTable("attractors");

			entity.Property(e => e.Id).HasColumnName("id");
			entity.Property(e => e.FormulaLatex).HasColumnName("formula_latex");
			entity.Property(e => e.RSquared).HasColumnName("r_squared");
			entity.Property(e => e.IsStable).HasColumnName("is_stable");
			entity.Property(e => e.CreatedAt).HasColumnName("created_at");
		});
	}
}
