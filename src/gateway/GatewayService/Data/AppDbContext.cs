using GatewayService.Models;
using Microsoft.EntityFrameworkCore;

namespace GatewayService.Data;

public class AppDbContext : DbContext {
	public AppDbContext(DbContextOptions<AppDbContext> options) : base(options) { }
	public DbSet<Attractor> Attractors => Set<Attractor>();
}

