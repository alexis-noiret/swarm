<?php
echo "<h1>Swarm PCA/PRA</h1>";
echo "<p>Conteneur PHP : " . gethostname() . "</p>";
try {
    $pass = trim(file_get_contents('/run/secrets/db_app_password'));
    $pdo = new PDO("mysql:host=db;dbname=app;charset=utf8mb4", "app", $pass,
                   [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $pdo->exec("CREATE TABLE IF NOT EXISTS visites (id INT AUTO_INCREMENT PRIMARY KEY, conteneur VARCHAR(64), date_visite DATETIME DEFAULT CURRENT_TIMESTAMP)");
    $st = $pdo->prepare("INSERT INTO visites (conteneur) VALUES (?)");
    $st->execute([gethostname()]);
    $n = $pdo->query("SELECT COUNT(*) FROM visites")->fetchColumn();
    echo "<p>Base MariaDB : OK, $n visites enregistrées</p>";
} catch (Exception $e) {
    echo "<p>Base MariaDB : ERREUR, " . htmlspecialchars($e->getMessage()) . "</p>";
}
